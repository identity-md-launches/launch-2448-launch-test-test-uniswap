// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice A single factory-bound TEST/IMD pool: IMD fees, swap pause, and a timed buyer allowlist.
/// @dev No ownership transfer, upgrades, approvals, arbitrary calls, or token withdrawals.
contract TestHook is IUnlockCallback {
    using SafeCast for uint256;

    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant FEE_RECIPIENT = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS = 10_000;
    uint256 public constant ALLOWLIST_DURATION = 15 minutes;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable factory;

    struct PoolState {
        address token;
        bool paused;
        bool started;
        uint256 firstSwapTimestamp;
        uint256 pendingFees;
        mapping(address wallet => bool) allowed;
    }

    mapping(PoolId poolId => PoolState) private _pools;
    bool private _bound;
    bool private _entered;
    bool private _claimActive;
    PoolId private _claimPool;

    error OnlyPoolManager();
    error OnlyOwner();
    error OnlyFactory();
    error InvalidAddress();
    error AlreadyBound();
    error InvalidPool();
    error UnknownPool(PoolId poolId);
    error SwapsPaused(PoolId poolId);
    error BuyerNotAllowed(PoolId poolId, address wallet);
    error PartialIMDFill(int256 expected, int256 actual);
    error Reentrancy();
    error UnexpectedUnlock();

    event PoolBound(PoolId indexed poolId, address indexed token);
    event PauseChanged(PoolId indexed poolId, bool paused);
    event AllowedChanged(PoolId indexed poolId, address indexed wallet, bool allowed);
    event TradingStarted(PoolId indexed poolId, uint256 timestamp);
    event FeePaid(PoolId indexed poolId, uint256 amount);
    event FeeClaimMinted(PoolId indexed poolId, uint256 amount);
    event FeeClaimRedeemed(PoolId indexed poolId, uint256 amount);

    constructor(IPoolManager manager_, address owner_, address factory_) {
        if (address(manager_) == address(0) || owner_ == address(0) || factory_ == address(0)) {
            revert InvalidAddress();
        }
        poolManager = manager_;
        owner = owner_;
        factory = factory_;
        // Pure address-bit validation; the constructor does not call any outside contract.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice Address permission mask: 0x20cc (8396).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (_bound) revert AlreadyBound();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || c0 == address(0) || c0 >= c1 || (c0 != IMD && c1 != IMD)
                || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
        ) revert InvalidPool();

        PoolId poolId = key.toId();
        address launchToken = c0 == IMD ? c1 : c0;
        _bound = true;
        _pools[poolId].token = launchToken;
        emit PoolBound(poolId, launchToken);
        return IHooks.beforeInitialize.selector;
    }

    function pause(PoolId poolId) external onlyOwner {
        _pool(poolId).paused = true;
        emit PauseChanged(poolId, true);
    }

    function unpause(PoolId poolId) external onlyOwner {
        _pool(poolId).paused = false;
        emit PauseChanged(poolId, false);
    }

    function setAllowed(PoolId poolId, address[] calldata accounts, bool allowed) external onlyOwner {
        PoolState storage state = _pool(poolId);
        for (uint256 i; i < accounts.length; ++i) {
            state.allowed[accounts[i]] = allowed;
            emit AllowedChanged(poolId, accounts[i], allowed);
        }
    }

    function paused(PoolId poolId) external view returns (bool) {
        return _pool(poolId).paused;
    }

    function isAllowed(PoolId poolId, address wallet) external view returns (bool) {
        return _pool(poolId).allowed[wallet];
    }

    function token(PoolId poolId) external view returns (address) {
        return _pool(poolId).token;
    }

    /// @notice Reads TEST's actual supply; no pair supply or cached launch-supply surrogate.
    function totalSupply(PoolId poolId) external view returns (uint256) {
        return IERC20(_pool(poolId).token).totalSupply();
    }

    function firstSwapTimestamp(PoolId poolId) external view returns (uint256) {
        return _pool(poolId).firstSwapTimestamp;
    }

    function hasStarted(PoolId poolId) external view returns (bool) {
        return _pool(poolId).started;
    }

    function allowlistActive(PoolId poolId) external view returns (bool) {
        PoolState storage state = _pool(poolId);
        return !state.started || block.timestamp - state.firstSwapTimestamp < ALLOWLIST_DURATION;
    }

    function pendingFees(PoolId poolId) external view returns (uint256) {
        return _pool(poolId).pendingFees;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _pool(poolId);
        if (state.paused) revert SwapsPaused(poolId);
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        bool buying = params.zeroForOne == imdIs0;
        if (
            buying && (!state.started || block.timestamp - state.firstSwapTimestamp < ALLOWLIST_DURATION)
                && !state.allowed[tx.origin]
        ) revert BuyerNotAllowed(poolId, tx.origin);

        int128 fee = 0;
        if (_imdSpecified(params, imdIs0)) fee = _specifiedFee(params.amountSpecified).toInt128();
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _pool(poolId);
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        int128 pairDelta = imdIs0 ? delta.amount0() : delta.amount1();
        bool specified = _imdSpecified(params, imdIs0);
        uint256 fee;
        if (specified) {
            fee = _specifiedFee(params.amountSpecified);
            // beforeSwap adds a positive specified delta: reduce input or increase output.
            // Checking the core delta here prevents charging a requested but unfilled amount.
            int256 expected = params.amountSpecified + int256(fee);
            if (int256(pairDelta) != expected) revert PartialIMDFill(expected, int256(pairDelta));
        } else {
            uint256 traded = pairDelta < 0 ? uint256(-int256(pairDelta)) : uint256(int256(pairDelta));
            // Buy: core input is net of the fee; gross it up. Sell: core output is already gross.
            fee = FullMath.mulDiv(traded, FEE_BPS, pairDelta < 0 ? BPS - FEE_BPS : BPS);
        }

        int128 feeDelta = fee.toInt128();
        if (!state.started && (delta.amount0() != 0 || delta.amount1() != 0)) {
            state.started = true;
            state.firstSwapTimestamp = block.timestamp;
            emit TradingStarted(poolId, block.timestamp);
        }
        if (fee != 0) _payOrMint(poolId, state, fee);
        // Specified-side fees were returned in beforeSwap; never charge them a second time.
        return (IHooks.afterSwap.selector, specified ? int128(0) : feeDelta);
    }

    /// @notice Anyone can redeem this pool's IMD claims to the fixed recipient, including while paused.
    /// @dev Call outside an existing PoolManager unlock. Redeems up to its available IMD balance.
    function claimFees(PoolId poolId) external nonReentrant returns (uint256 redeemed) {
        if (_pool(poolId).pendingFees == 0) return 0;
        _claimActive = true;
        _claimPool = poolId;
        redeemed = abi.decode(poolManager.unlock(abi.encode(poolId)), (uint256));
        _claimActive = false;
        _claimPool = PoolId.wrap(bytes32(0));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolId poolId = abi.decode(data, (PoolId));
        if (!_claimActive || PoolId.unwrap(poolId) != PoolId.unwrap(_claimPool)) revert UnexpectedUnlock();
        // Consume the authorization before any external interaction.
        _claimActive = false;
        PoolState storage state = _pool(poolId);
        Currency imd = Currency.wrap(IMD);
        uint256 amount = state.pendingFees;
        uint256 available = imd.balanceOf(address(poolManager));
        if (amount > available) amount = available;
        if (amount != 0) {
            state.pendingFees -= amount;
            poolManager.burn(address(this), imd.toId(), amount);
            poolManager.take(imd, FEE_RECIPIENT, amount);
            emit FeeClaimRedeemed(poolId, amount);
        }
        return abi.encode(amount);
    }

    function _payOrMint(PoolId poolId, PoolState storage state, uint256 fee) private {
        Currency imd = Currency.wrap(IMD);
        if (imd.balanceOf(address(poolManager)) >= fee) {
            // A rejected ERC-20 transfer rolls back take's delta before falling back to a claim.
            try poolManager.take(imd, FEE_RECIPIENT, fee) {
                emit FeePaid(poolId, fee);
                return;
            } catch {}
        }
        state.pendingFees += fee;
        poolManager.mint(address(this), imd.toId(), fee);
        emit FeeClaimMinted(poolId, fee);
    }

    function _pool(PoolId poolId) private view returns (PoolState storage state) {
        state = _pools[poolId];
        if (state.token == address(0)) revert UnknownPool(poolId);
    }

    function _imdSpecified(SwapParams calldata params, bool imdIs0) private pure returns (bool) {
        return (params.zeroForOne == (params.amountSpecified < 0)) == imdIs0;
    }

    function _specifiedFee(int256 amount) private pure returns (uint256) {
        if (amount < 0) {
            // This absolute value also handles int256.min without signed overflow.
            uint256 grossInput = uint256(-(amount + 1)) + 1;
            return FullMath.mulDiv(grossInput, FEE_BPS, BPS);
        }
        // An exact-output IMD sell specifies the net amount the trader must receive.
        return FullMath.mulDiv(uint256(amount), FEE_BPS, BPS - FEE_BPS);
    }
}
