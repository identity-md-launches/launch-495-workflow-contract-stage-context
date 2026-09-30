// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PepeJackpot} from "../../src/PepeJackpot.sol";

/// @dev Local test asset, deliberately able to model an ERC-20 that rejects a recipient.
contract JackpotTestToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;
    mapping(address => uint8) public transferFailure;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address public callbackRecipient;
    address public callbackTarget;
    bytes public callbackData;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory tokenName, string memory tokenSymbol) {
        name = tokenName;
        symbol = tokenSymbol;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(tokenName)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function failTransfersTo(address recipient, uint8 mode) external {
        transferFailure[recipient] = mode;
    }

    function setCallback(address recipient, address target, bytes calldata data) external {
        callbackRecipient = recipient;
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferFailure[to] == 1) return false;
        require(transferFailure[to] != 2, "recipient rejected");
        _transfer(msg.sender, to, amount);
        return transferFailure[to] != 3;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        _transfer(from, to, amount);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "expired permit");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        require(owner != address(0) && ecrecover(digest, v, r, s) == owner, "invalid permit");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        if (to == callbackRecipient && callbackTarget != address(0)) {
            (bool ok,) = callbackTarget.call(callbackData);
            require(ok, "token callback failed");
        }
    }
}

interface IJackpotRandomReceiver {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external;
}

contract JackpotTestVRF {
    uint256 public price = 0.0001 ether;
    uint256 public requestCount;
    bool public shouldFail;
    uint32 public lastGasLimit;
    uint16 public lastConfirmations;
    uint32 public lastNumWords;
    bytes public lastExtraArgs;
    mapping(uint256 => address) public consumers;

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function setFailure(bool value) external {
        shouldFail = value;
    }

    function requestRandomWordsInNative(
        uint32 gasLimit,
        uint16 confirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId) {
        require(!shouldFail, "wrapper unavailable");
        require(msg.value == price, "wrong native fee");
        lastGasLimit = gasLimit;
        lastConfirmations = confirmations;
        lastNumWords = numWords;
        lastExtraArgs = extraArgs;
        requestId = ++requestCount;
        consumers[requestId] = msg.sender;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IJackpotRandomReceiver(consumers[requestId]).rawFulfillRandomWords(requestId, words);
    }

    function fulfillWords(address consumer, uint256 requestId, uint256[] calldata words) external {
        IJackpotRandomReceiver(consumer).rawFulfillRandomWords(requestId, words);
    }
}

/// @dev Uses an actual v4 PoolManager; the only simulated launchpad behavior is its hook.
contract JackpotTestLaunchpadHook {
    uint256 public swaps;
    bool public rejectSwap;

    function setRejectSwap(bool reject) external {
        rejectSwap = reject;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(!rejectSwap, "launchpad rejects swap");
        ++swaps;
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

/// @dev Supplies real liquidity and settles each of the manager's currency deltas.
contract JackpotLiquidityFixture is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external payable {
        manager.unlock(abi.encode(msg.sender, key, lower, upper, liquidity));
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "liquidity refund");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, int24 lower, int24 upper, int256 liquidity) =
            abi.decode(data, (address, PoolKey, int24, int24, int256));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return "";
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        require(amount <= 0, "adding liquidity only");
        uint256 debt = uint256(-int256(amount));
        manager.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            manager.settle{value: debt}();
        } else {
            JackpotTestToken(Currency.unwrap(currency)).transferFrom(payer, address(manager), debt);
            manager.settle();
        }
    }
    receive() external payable {}
}

contract JackpotActor {
    address public immutable jackpot;
    bool public rejectEther;
    bool public tryReenter;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes public reentryData;

    constructor(address game) {
        jackpot = game;
    }

    function configure(bool reject, bool reenter, bytes calldata data) external {
        rejectEther = reject;
        tryReenter = reenter;
        reentryData = data;
    }

    function approve(JackpotTestToken token, uint256 amount) external {
        token.approve(jackpot, amount);
    }

    function execute(bytes calldata data) external payable returns (bytes memory result) {
        (bool ok, bytes memory value) = jackpot.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(value, 32), mload(value)) }
        }
        return value;
    }

    function tokenCallback() external {
        _attempt();
    }

    function _attempt() private {
        if (tryReenter) {
            ++attempts;
            (reentrySucceeded,) = jackpot.call(reentryData);
        }
    }

    receive() external payable {
        require(!rejectEther, "reject ether");
        _attempt();
    }
}

/// @dev Relays an oracle word from inside its own PoolManager.unlock, while the manager's global lock is held.
/// The production wrapper swallows consumer reverts; the local wrapper does not, so the relay swallows them.
contract JackpotForeignUnlockRelay is IUnlockCallback {
    IPoolManager public immutable manager;
    JackpotTestVRF public immutable wrapper;
    bool public delivered;

    constructor(IPoolManager poolManager, JackpotTestVRF vrf) {
        manager = poolManager;
        wrapper = vrf;
    }

    function deliver(uint256 requestId, uint256 word) external {
        manager.unlock(abi.encode(requestId, word));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint256 requestId, uint256 word) = abi.decode(data, (uint256, uint256));
        (delivered,) = address(wrapper).call(abi.encodeCall(wrapper.fulfill, (requestId, word)));
        return "";
    }
}

/// @dev Relays an oracle word from the ETH refund of its own sub-threshold trade, while the jackpot's guard is held.
contract JackpotRefundRelay {
    PepeJackpot public immutable jackpot;
    JackpotTestVRF public immutable wrapper;
    uint256 private requestId;
    uint256 private word;
    bool public attempted;
    bool public delivered;

    constructor(PepeJackpot game, JackpotTestVRF vrf) {
        jackpot = game;
        wrapper = vrf;
    }

    function approve(JackpotTestToken token) external {
        token.approve(address(jackpot), type(uint256).max);
    }

    function deliverFromRefund(uint256 id, uint256 randomWord) external payable {
        requestId = id;
        word = randomWord;
        jackpot.fridgeSwap{value: msg.value}(true, 1 ether, 1, block.timestamp);
    }

    receive() external payable {
        attempted = true;
        (delivered,) = address(wrapper).call(abi.encodeCall(wrapper.fulfill, (requestId, word)));
    }
}
