// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IJackpotERC20, IJackpotVRFWrapper} from "./interfaces/IJackpotTokens.sol";
import {V4ViewQuoter} from "./libraries/V4ViewQuoter.sol";

/// @notice Immutable ICE jackpot and two-pool router. No administrative or rescue privileges.
/// @dev All value actions execute in one authenticated PoolManager unlock. See README for trust assumptions.
contract PepeJackpot is IUnlockCallback {
    error InvalidConfiguration();
    error InvalidAmount();
    error ExpiredDeadline();
    error ReentrantCall();
    error UnauthorizedCallback();
    error Slippage();
    error PartialFill();
    error TokenTransferFailed();
    error InsufficientVRFFee();
    error RefundFailed();
    error NothingToClaim();
    error TicketNotPending();
    error TicketNotExpired();

    uint256 public constant ICE_TICKET_MIN = 10_000 ether;
    uint256 public constant IMD_TICKET_MIN = 0.1 ether;
    uint256 public constant ETH_TICKET_MIN = 0.001 ether;
    uint256 public constant ICE_PER_PEE = 1_000 ether;
    uint256 public constant TICKET_LIFETIME = 24 hours;
    uint32 public constant CALLBACK_GAS_LIMIT = 500_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint256 private constant PAYOUT_GAS_LIMIT = 100_000;

    IPoolManager public immutable poolManager;
    IJackpotERC20 public immutable ice;
    IJackpotERC20 public immutable imd;
    IHooks public immutable iceHook;
    IJackpotVRFWrapper public immutable vrfWrapper;

    enum TicketStatus {
        None,
        Pending,
        Drawn,
        Expired
    }

    struct Ticket {
        address player;
        uint48 issuedAt;
        uint8 roll;
        TicketStatus status;
        uint256 fee;
        uint256 payout;
    }

    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
    enum Action {
        Fridge,
        Throne,
        Seed,
        Tank,
        Fulfill,
        Claim
    }

    mapping(uint256 => Ticket) public tickets;
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;
    bool private entered;
    bytes32 private pendingUnlock;

    event TicketIssued(uint256 indexed requestId, address indexed player, uint256 fee, uint256 expiresAt);
    event Drawn(uint256 indexed requestId, address indexed player, uint8 roll, uint256 payout, bool deferred);
    event TicketExpired(uint256 indexed requestId);
    event Seeded(address indexed player, uint256 amount);
    event TankFilled(address indexed player, uint256 pees, uint256 amount);
    event FridgeSwapped(address indexed player, bool iceToImd, uint256 amountIn, uint256 amountOut, uint256 iceFee);
    event ThroneSwapped(address indexed player, uint256 ethIn, uint256 imdOut, uint256 iceFee);
    event Claimed(address indexed player, uint256 amount);

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /// @dev Pool keys are represented by their variable addresses; fees, spacing and native currency are fixed.
    constructor(address manager_, address ice_, address iceHook_, address imd_, address wrapper_) {
        if (
            manager_ == address(0) || ice_ == address(0) || imd_ == address(0) || iceHook_ == address(0)
                || wrapper_ == address(0) || ice_ == imd_
        ) {
            revert InvalidConfiguration();
        }
        poolManager = IPoolManager(manager_);
        ice = IJackpotERC20(ice_);
        imd = IJackpotERC20(imd_);
        iceHook = IHooks(iceHook_);
        vrfWrapper = IJackpotVRFWrapper(wrapper_);
    }

    function launchpadPoolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(ice)), 0, 60, iceHook);
    }

    function imdPoolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
    }

    /// @notice Available pot; outstanding failed payouts are already reserved and cannot win again.
    function pot() public view returns (uint256) {
        return ice.balanceOf(address(this)) - totalClaimable;
    }

    /// @notice Quote using the transaction's gas price, as required by the wrapper.
    function vrfFee() public view returns (uint256) {
        return vrfWrapper.calculateRequestPriceNative(CALLBACK_GAS_LIMIT, 1);
    }

    /// @notice Current execution estimate including launchpad curve, hook fees and sequential pool impact.
    /// @dev Not an oracle or execution guarantee; specify a minimum output and deadline on the trade.
    function quoteFridgeSwap(bool iceToImd, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 iceFee)
    {
        _validAmount(amountIn);
        return V4ViewQuoter.quoteFridge(poolManager, launchpadPoolKey(), imdPoolKey(), iceToImd, amountIn);
    }

    function quoteGoldenThrone(uint256 ethIn) external view returns (uint256 imdOut, uint256 iceFee) {
        _validAmount(ethIn);
        return V4ViewQuoter.quoteThrone(poolManager, launchpadPoolKey(), imdPoolKey(), ethIn);
    }

    function fridgeSwap(bool iceToImd, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 ticketId)
    {
        _checkTrade(amountIn, minOut, deadline);
        return abi.decode(
            _unlock(abi.encode(Action.Fridge, msg.sender, msg.value, abi.encode(iceToImd, amountIn, minOut))),
            (uint256, uint256)
        );
    }

    /// @param ethIn ETH to trade, separate from msg.value's VRF fee and refundable excess.
    /// @param minIceFee Minimum ICE obtained with the 1% ETH ticket allocation.
    function goldenThrone(uint256 ethIn, uint256 minImdOut, uint256 minIceFee, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 ticketId)
    {
        _checkTrade(ethIn, minImdOut, deadline);
        if (minIceFee == 0 || ethIn / 100 == 0) revert InvalidAmount();
        if (msg.value < ethIn) revert InsufficientVRFFee();
        return abi.decode(
            _unlock(abi.encode(Action.Throne, msg.sender, msg.value, abi.encode(ethIn, minImdOut, minIceFee))),
            (uint256, uint256)
        );
    }

    function seed(uint256 amount) external nonReentrant {
        _validAmount(amount);
        _unlock(abi.encode(Action.Seed, msg.sender, 0, abi.encode(amount)));
    }

    function fillTank(uint256 pees, Permit calldata permitData) external nonReentrant {
        if (pees == 0 || pees > uint256(uint128(type(int128).max)) / ICE_PER_PEE) revert InvalidAmount();
        _unlock(abi.encode(Action.Tank, msg.sender, 0, abi.encode(pees, permitData)));
    }

    function claim() external nonReentrant {
        if (claimable[msg.sender] == 0) revert NothingToClaim();
        _unlock(abi.encode(Action.Claim, msg.sender, 0, bytes("")));
    }

    /// @notice Permissionless expiry; ticket fees and paid oracle fees are never refundable.
    function expire(uint256 requestId) external nonReentrant {
        Ticket storage t = tickets[requestId];
        if (t.status != TicketStatus.Pending) revert TicketNotPending();
        if (block.timestamp < uint256(t.issuedAt) + TICKET_LIFETIME) revert TicketNotExpired();
        t.status = TicketStatus.Expired;
        emit TicketExpired(requestId);
    }

    /// @dev Only the immutable wrapper can supply randomness. Duplicate/unknown/malformed callbacks are ignored.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        if (msg.sender != address(vrfWrapper)) revert UnauthorizedCallback();
        if (tickets[requestId].status != TicketStatus.Pending || randomWords.length != 1) return;
        _unlock(abi.encode(Action.Fulfill, address(0), 0, abi.encode(requestId, randomWords[0])));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (
            msg.sender != address(poolManager) || !entered || pendingUnlock == bytes32(0)
                || keccak256(data) != pendingUnlock
        ) revert UnauthorizedCallback();
        pendingUnlock = bytes32(0);
        (Action action, address player, uint256 ethBudget, bytes memory args) =
            abi.decode(data, (Action, address, uint256, bytes));
        if (action == Action.Fridge) return _fridge(player, ethBudget, args);
        if (action == Action.Throne) return _throne(player, ethBudget, args);
        if (action == Action.Seed) {
            uint256 amount = abi.decode(args, (uint256));
            _pullExact(ice, player, address(this), amount);
            emit Seeded(player, amount);
        } else if (action == Action.Tank) {
            (uint256 pees, Permit memory p) = abi.decode(args, (uint256, Permit));
            uint256 amount = pees * ICE_PER_PEE;
            // A third party may have already submitted this permit. Existing allowance remains sufficient authority.
            try ice.permit(player, address(this), amount, p.deadline, p.v, p.r, p.s) {}
            catch {
                if (ice.allowance(player, address(this)) < amount) revert TokenTransferFailed();
            }
            _pullExact(ice, player, address(this), amount);
            emit TankFilled(player, pees, amount);
        } else if (action == Action.Fulfill) {
            (uint256 id, uint256 word) = abi.decode(args, (uint256, uint256));
            _draw(id, word);
        } else {
            uint256 amount = claimable[player];
            claimable[player] = 0;
            totalClaimable -= amount;
            if (!_tryPayout(player, amount)) revert TokenTransferFailed();
            emit Claimed(player, amount);
        }
        return bytes("");
    }

    function _fridge(address player, uint256 ethBudget, bytes memory args) private returns (bytes memory) {
        (bool iceToImd, uint256 amountIn, uint256 minOut) = abi.decode(args, (bool, uint256, uint256));
        uint256 fee;
        uint256 output;
        if (iceToImd) {
            fee = amountIn / 100;
            _pullExact(ice, player, address(this), fee);
            uint256 ethOut = _swap(launchpadPoolKey(), false, amountIn - fee);
            output = _swap(imdPoolKey(), true, ethOut);
            _settleToken(ice, player, amountIn - fee);
            poolManager.take(Currency.wrap(address(imd)), player, output);
        } else {
            uint256 ethOut = _swap(imdPoolKey(), false, amountIn);
            uint256 grossIce = _swap(launchpadPoolKey(), true, ethOut);
            fee = grossIce / 100;
            output = grossIce - fee;
            _settleToken(imd, player, amountIn);
            poolManager.take(Currency.wrap(address(ice)), address(this), fee);
            poolManager.take(Currency.wrap(address(ice)), player, output);
        }
        if (output < minOut) revert Slippage();
        bool eligible = amountIn >= (iceToImd ? ICE_TICKET_MIN : IMD_TICKET_MIN);
        uint256 id = _ticketAndRefund(player, fee, eligible, ethBudget);
        emit FridgeSwapped(player, iceToImd, amountIn, output, fee);
        return abi.encode(output, id);
    }

    function _throne(address player, uint256 ethBudget, bytes memory args) private returns (bytes memory) {
        (uint256 ethIn, uint256 minOut, uint256 minFee) = abi.decode(args, (uint256, uint256, uint256));
        uint256 fee = _swap(launchpadPoolKey(), true, ethIn / 100);
        uint256 output = _swap(imdPoolKey(), true, ethIn - ethIn / 100);
        if (output < minOut || fee < minFee) revert Slippage();
        poolManager.sync(Currency.wrap(address(0)));
        if (poolManager.settle{value: ethIn}() != ethIn) revert PartialFill();
        poolManager.take(Currency.wrap(address(ice)), address(this), fee);
        poolManager.take(Currency.wrap(address(imd)), player, output);
        uint256 id = _ticketAndRefund(player, fee, ethIn >= ETH_TICKET_MIN, ethBudget - ethIn);
        emit ThroneSwapped(player, ethIn, output, fee);
        return abi.encode(output, id);
    }

    function _ticketAndRefund(address player, uint256 fee, bool eligible, uint256 budget) private returns (uint256 id) {
        uint256 price;
        if (eligible) {
            if (fee == 0) revert InvalidAmount();
            price = vrfFee();
            if (budget < price) revert InsufficientVRFFee();
            id = vrfWrapper.requestRandomWordsInNative{value: price}(
                CALLBACK_GAS_LIMIT,
                REQUEST_CONFIRMATIONS,
                1,
                abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
            );
            if (id == 0 || tickets[id].status != TicketStatus.None) revert InvalidConfiguration();
            tickets[id] = Ticket(player, uint48(block.timestamp), 0, TicketStatus.Pending, fee, 0);
            emit TicketIssued(id, player, fee, block.timestamp + TICKET_LIFETIME);
        }
        if (budget > price) {
            (bool ok,) = player.call{value: budget - price}("");
            if (!ok) revert RefundFailed();
        }
    }

    function _draw(uint256 id, uint256 word) private {
        Ticket storage t = tickets[id];
        if (block.timestamp >= uint256(t.issuedAt) + TICKET_LIFETIME) {
            t.status = TicketStatus.Expired;
            emit TicketExpired(id);
            return;
        }
        uint8 roll = uint8(word % 100 + 1);
        uint256 available = pot();
        uint256 payout;
        if (roll == 77) {
            // Exact floor(available * 90 / 100), without multiplication overflow.
            payout = available / 10 * 9 + (available % 10) * 9 / 10;
        } else if (roll % 20 == 0) {
            uint256 cap = available / 10;
            payout = t.fee > cap / 20 ? cap : t.fee * 20;
        }
        t.roll = roll;
        t.payout = payout;
        t.status = TicketStatus.Drawn;
        bool deferred;
        if (payout != 0 && !_tryPayout(t.player, payout)) {
            claimable[t.player] += payout;
            totalClaimable += payout;
            deferred = true;
        }
        emit Drawn(id, t.player, roll, payout, deferred);
    }

    /// @dev Isolated call makes false-return/malformed-return transfers revert their token-side state too.
    function deliverPayout(address player, uint256 amount) external {
        if (msg.sender != address(this) || !entered) revert UnauthorizedCallback();
        uint256 beforeSelf = ice.balanceOf(address(this));
        uint256 beforePlayer = ice.balanceOf(player);
        _tokenCall(address(ice), abi.encodeCall(IJackpotERC20.transfer, (player, amount)));
        if (ice.balanceOf(address(this)) != beforeSelf - amount || ice.balanceOf(player) != beforePlayer + amount) {
            revert TokenTransferFailed();
        }
    }

    function _tryPayout(address player, uint256 amount) private returns (bool ok) {
        (ok,) = address(this).call{gas: PAYOUT_GAS_LIMIT}(abi.encodeCall(this.deliverPayout, (player, amount)));
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) private returns (uint256 output) {
        _validAmount(amountIn);
        BalanceDelta d = poolManager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outputDelta = zeroForOne ? d.amount1() : d.amount0();
        if (int256(inputDelta) != -int256(amountIn) || outputDelta <= 0) revert PartialFill();
        output = uint256(uint128(outputDelta));
    }

    function _settleToken(IJackpotERC20 token, address player, uint256 amount) private {
        poolManager.sync(Currency.wrap(address(token)));
        _pullExact(token, player, address(poolManager), amount);
        if (poolManager.settle() != amount) revert TokenTransferFailed();
    }

    function _pullExact(IJackpotERC20 token, address from, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(to);
        _tokenCall(address(token), abi.encodeCall(IJackpotERC20.transferFrom, (from, to, amount)));
        if (token.balanceOf(to) != beforeBalance + amount) revert TokenTransferFailed();
    }

    function _tokenCall(address token, bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenTransferFailed();
        }
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        pendingUnlock = keccak256(data);
        result = poolManager.unlock(data);
        if (pendingUnlock != bytes32(0)) revert UnauthorizedCallback();
    }

    function _validAmount(uint256 amount) private pure {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
    }

    function _checkTrade(uint256 amount, uint256 minOut, uint256 deadline) private view {
        _validAmount(amount);
        if (minOut == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert ExpiredDeadline();
    }
}
