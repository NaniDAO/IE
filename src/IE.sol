// ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘ ⌘
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {MetadataReaderLib} from "../lib/solady/src/utils/MetadataReaderLib.sol";

/// @title Intents Engine (IE)
/// @notice Simple helper contract for turning transactional intents into executable code.
/// @dev V1 simulates typical commands (sending and swapping tokens) and includes execution.
/// IE also has a workflow to verify the intent of ERC4337 account userOps against calldata.
/// @author nani.eth (https://github.com/NaniDAO/ie)
/// @custom:version 1.3.0
contract IE {
    /// ======================= LIBRARY USAGE ======================= ///

    /// @dev Token transfer library.
    using SafeTransferLib for address;

    /// @dev Token metadata reader library.
    using MetadataReaderLib for address;

    /// ======================= CUSTOM ERRORS ======================= ///

    /// @dev Bad math.
    error Overflow();

    /// @dev 0-liquidity.
    error InvalidSwap();

    /// @dev Invalid command.
    error InvalidSyntax();

    /// @dev Non-numeric character.
    error InvalidCharacter();

    /// @dev Insufficient swap output.
    error InsufficientSwap();

    /// @dev Invalid selector for the given asset spend.
    error InvalidSelector();

    /// =========================== EVENTS =========================== ///

    /// @dev Logs the registration of a token name alias.
    event AliasSet(address indexed token, string name);

    /// @dev Logs the registration of a token swap pool pair route on Uniswap V3.
    event PairSet(address indexed token0, address indexed token1, address pair);

    /// ========================== STRUCTS ========================== ///

    /// @dev The ERC4337 user operation (userOp) struct.
    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        uint256 callGasLimit;
        uint256 verificationGasLimit;
        uint256 preVerificationGas;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        bytes paymasterAndData;
        bytes signature;
    }

    /// @dev The packed ERC4337 userOp struct.
    struct PackedUserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }

    /// @dev The `swap` command information struct.
    struct SwapInfo {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        bool ETHIn;
        bool ETHOut;
    }

    /// @dev The `swap` pool liquidity struct.
    struct SwapLiq {
        address pool;
        uint256 liq;
    }

    /// ========================= CONSTANTS ========================= ///

    /// @dev The governing DAO address.
    address internal constant DAO = 0xDa000000000000d2885F108500803dfBAaB2f2aA;

    /// @dev The NANI token address.
    address internal constant NANI = 0x000000000000C6A645b0E51C9eCAA4CA580Ed8e8;

    /// @dev The conventional ERC7528 ETH address.
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev The canonical wrapped ETH address.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @dev The popular wrapped BTC address.
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    /// @dev The Circle USD stablecoin address.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev The Tether USD stablecoin address.
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    /// @dev The Maker DAO USD stablecoin address.
    address internal constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    /// @dev The Arbitrum DAO governance token address.
    address internal constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    /// @dev The Lido Wrapped Staked ETH token address.
    address internal constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

    /// @dev The Rocket Pool Staked ETH token address.
    address internal constant RETH = 0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8;

    /// @dev The address of the Uniswap V3 Factory.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev The Uniswap V3 Pool `initcodehash`.
    bytes32 internal constant UNISWAP_V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    /// @dev The minimum value that can be returned from `getSqrtRatioAtTick` (plus one).
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;

    /// @dev The maximum value that can be returned from `getSqrtRatioAtTick` (minus one).
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE =
        1461446703485210103287273052203988822378723970341;

    /// ========================== STORAGE ========================== ///

    /// @dev DAO-governed NAMI naming system on Arbitrum.
    INAMI internal nami = INAMI(0x000000006641B4C250AEA6B62A1e0067D300697a);

    /// @dev DAO-governed token name aliasing.
    mapping(string name => address) public tokens;

    /// @dev DAO-governed token address name aliasing.
    mapping(address token => string name) public aliases;

    /// @dev DAO-governed token swap pool routing on Uniswap V3.
    mapping(address token0 => mapping(address token1 => address)) public pairs;

    /// ======================== CONSTRUCTOR ======================== ///

    /// @dev Constructs this IE on the Arbitrum L2 of Ethereum.
    constructor() payable {}

    /// ====================== COMMAND PREVIEW ====================== ///

    /// @dev Preview natural language smart contract command.
    /// The `send` syntax uses ENS naming: 'send vitalik 20 DAI'.
    /// `swap` syntax uses common format: 'swap 100 DAI for WETH'.
    function previewCommand(string calldata intent)
        public
        view
        virtual
        returns (
            address to, // Receiver address.
            uint256 amount, // Formatted amount.
            uint256 minAmountOut, // Formatted amount.
            address token, // Asset to send `to`.
            bytes memory callData, // Raw calldata for send transaction.
            bytes memory executeCallData // Anticipates common execute API.
        )
    {
        string memory normalized = _lowercase(intent);
        bytes32 action = _extraction(normalized);
        if (action == "send" || action == "transfer" || action == "pay" || action == "grant") {
            (string memory _to, string memory _amount, string memory _token) =
                _extractSend(normalized);
            (to, amount, token, callData, executeCallData) = previewSend(_to, _amount, _token);
        } else if (
            action == "swap" || action == "exchange" || action == "stake" || action == "deposit"
                || action == "unstake" || action == "withdraw"
        ) {
            (
                string memory amountIn,
                string memory amountOutMinimum,
                string memory tokenIn,
                string memory tokenOut
            ) = _extractSwap(normalized);
            (amount, minAmountOut, token, to) =
                previewSwap(amountIn, amountOutMinimum, tokenIn, tokenOut);
        } else {
            revert InvalidSyntax(); // Invalid command format.
        }
    }

    /// @dev Previews a `send` command from the parts of a matched intent string.
    function previewSend(string memory to, string memory amount, string memory token)
        public
        view
        virtual
        returns (
            address _to,
            uint256 _amount,
            address _token,
            bytes memory callData,
            bytes memory executeCallData
        )
    {
        uint256 decimals;
        (_token, decimals) = _returnTokenConstants(bytes32(bytes(token)));
        if (_token == address(0)) _token = tokens[token]; // Check storage.
        bool isETH = _token == ETH; // Memo whether the token is ETH or not.
        (, _to,) = whatIsTheAddressOf(to); // Fetch receiver address from ENS.
        _amount = _toUint(amount, decimals != 0 ? decimals : _token.readDecimals());
        if (!isETH) callData = abi.encodeCall(IToken.transfer, (_to, _amount));
        executeCallData =
            abi.encodeCall(IExecutor.execute, (isETH ? _to : _token, isETH ? _amount : 0, callData));
    }

    /// @dev Previews a `swap` command from the parts of a matched intent string.
    function previewSwap(
        string memory amountIn,
        string memory amountOutMinimum,
        string memory tokenIn,
        string memory tokenOut
    )
        public
        view
        virtual
        returns (uint256 _amountIn, uint256 _amountOut, address _tokenIn, address _tokenOut)
    {
        uint256 decimalsIn;
        uint256 decimalsOut;
        (_tokenIn, decimalsIn) = _returnTokenConstants(bytes32(bytes(tokenIn)));
        if (_tokenIn == address(0)) _tokenIn = tokens[tokenIn];
        (_tokenOut, decimalsOut) = _returnTokenConstants(bytes32(bytes(tokenOut)));
        if (_tokenOut == address(0)) _tokenOut = tokens[tokenOut];
        _amountIn = _toUint(amountIn, decimalsIn != 0 ? decimalsIn : _tokenIn.readDecimals());
        _amountOut =
            _toUint(amountOutMinimum, decimalsOut != 0 ? decimalsOut : _tokenOut.readDecimals());
    }

    /// @dev Checks ERC4337 userOp against the output of the command intent.
    function checkUserOp(string calldata intent, UserOperation calldata userOp)
        public
        view
        virtual
        returns (bool)
    {
        (,,,,, bytes memory executeCallData) = previewCommand(intent);
        if (executeCallData.length != userOp.callData.length) return false;
        return keccak256(executeCallData) == keccak256(userOp.callData);
    }

    /// @dev Checks packed ERC4337 userOp against the output of the command intent.
    function checkPackedUserOp(string calldata intent, PackedUserOperation calldata userOp)
        public
        view
        virtual
        returns (bool)
    {
        (,,,,, bytes memory executeCallData) = previewCommand(intent);
        if (executeCallData.length != userOp.callData.length) return false;
        return keccak256(executeCallData) == keccak256(userOp.callData);
    }

    /// @dev Checks and returns the canonical token address constant for a matched intent string.
    function _returnTokenConstants(bytes32 token)
        internal
        pure
        virtual
        returns (address _token, uint256 _decimals)
    {
        if (token == "eth" || token == "ether") return (ETH, 18);
        if (token == "usdc") return (USDC, 6);
        if (token == "usdt" || token == "tether") return (USDT, 6);
        if (token == "dai") return (DAI, 18);
        if (token == "arb" || token == "arbitrum") return (ARB, 18);
        if (token == "weth") return (WETH, 18);
        if (token == "wbtc" || token == "btc" || token == "bitcoin") return (WBTC, 8);
        if (token == "steth" || token == "wsteth" || token == "lido") return (WSTETH, 18);
        if (token == "reth") return (RETH, 18);
        if (token == "nani") return (NANI, 18);
    }

    /// @dev Checks and returns the canonical token string constant for a matched address.
    function _returnTokenAliasConstants(address token)
        internal
        pure
        virtual
        returns (string memory _token, uint256 _decimals)
    {
        if (token == USDC) return ("USDC", 6);
        if (token == USDT) return ("USDT", 6);
        if (token == DAI) return ("DAI", 18);
        if (token == ARB) return ("ARB", 18);
        if (token == WETH) return ("WETH", 18);
        if (token == WBTC) return ("WBTC", 8);
        if (token == WSTETH) return ("WSTETH", 18);
        if (token == RETH) return ("RETH", 18);
        if (token == NANI) return ("NANI", 18);
    }

    /// @dev Checks and returns popular pool pairs for WETH swaps.
    function _returnPoolConstants(address token0, address token1)
        internal
        pure
        virtual
        returns (address pool)
    {
        if (token0 == WSTETH && token1 == WETH) return 0x35218a1cbaC5Bbc3E57fd9Bd38219D37571b3537;
        if (token0 == WETH && token1 == RETH) return 0x09ba302A3f5ad2bF8853266e271b005A5b3716fe;
        if (token0 == WETH && token1 == USDC) return 0xC6962004f452bE9203591991D15f6b388e09E8D0;
        if (token0 == WETH && token1 == USDT) return 0x641C00A822e8b671738d32a431a4Fb6074E5c79d;
        if (token0 == WETH && token1 == DAI) return 0xA961F0473dA4864C5eD28e00FcC53a3AAb056c1b;
        if (token0 == WETH && token1 == ARB) return 0xC6F780497A95e246EB9449f5e4770916DCd6396A;
        if (token0 == WBTC && token1 == WETH) return 0x2f5e87C9312fa29aed5c179E456625D79015299c;
    }

    /// ===================== COMMAND EXECUTION ===================== ///

    /// @dev Executes a text command from an intent string.
    function command(string calldata intent) public payable virtual {
        string memory normalized = _lowercase(intent);
        bytes32 action = _extraction(normalized);
        if (action == "send" || action == "transfer" || action == "pay" || action == "grant") {
            (string memory to, string memory amount, string memory token) = _extractSend(normalized);
            send(to, amount, token);
        } else if (
            action == "swap" || action == "exchange" || action == "stake" || action == "deposit"
                || action == "unstake" || action == "withdraw"
        ) {
            (
                string memory amountIn,
                string memory amountOutMinimum,
                string memory tokenIn,
                string memory tokenOut
            ) = _extractSwap(normalized);
            swap(amountIn, amountOutMinimum, tokenIn, tokenOut);
        } else {
            revert InvalidSyntax(); // Invalid command format.
        }
    }

    /// @dev Executes a `send` command from the parts of a matched intent string.
    function send(string memory to, string memory amount, string memory token)
        public
        payable
        virtual
    {
        (address _token, uint256 decimals) = _returnTokenConstants(bytes32(bytes(token)));
        if (_token == address(0)) _token = tokens[token];
        (, address _to,) = whatIsTheAddressOf(to);
        if (_token == ETH) {
            _to.safeTransferETH(_toUint(amount, decimals));
        } else {
            _token.safeTransferFrom(
                msg.sender, _to, _toUint(amount, decimals != 0 ? decimals : _token.readDecimals())
            );
        }
    }

    /// @dev Executes a `swap` command from the parts of a matched intent string.
    function swap(
        string memory amountIn,
        string memory amountOutMinimum,
        string memory tokenIn,
        string memory tokenOut
    ) public payable virtual {
        SwapInfo memory info;
        uint256 decimalsIn;
        uint256 decimalsOut;
        (info.tokenIn, decimalsIn) = _returnTokenConstants(bytes32(bytes(tokenIn)));
        if (info.tokenIn == address(0)) info.tokenIn = tokens[tokenIn];
        (info.tokenOut, decimalsOut) = _returnTokenConstants(bytes32(bytes(tokenOut)));
        if (info.tokenOut == address(0)) info.tokenOut = tokens[tokenOut];
        info.ETHIn = info.tokenIn == ETH;
        if (info.ETHIn) info.tokenIn = WETH;
        info.ETHOut = info.tokenOut == ETH;
        if (info.ETHOut) info.tokenOut = WETH;
        info.amountIn =
            _toUint(amountIn, decimalsIn != 0 ? decimalsIn : info.tokenIn.readDecimals());
        if (info.amountIn >= 1 << 255) revert Overflow();
        (address pool, bool zeroForOne) = _computePoolAddress(info.tokenIn, info.tokenOut);
        (int256 amount0, int256 amount1) = ISwapRouter(pool).swap(
            !info.ETHOut ? msg.sender : address(this),
            zeroForOne,
            int256(info.amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encodePacked(info.ETHIn, info.ETHOut, msg.sender, info.tokenIn, info.tokenOut)
        );
        if (
            uint256(-(zeroForOne ? amount1 : amount0))
                < _toUint(
                    amountOutMinimum, decimalsOut != 0 ? decimalsOut : info.tokenOut.readDecimals()
                )
        ) revert InsufficientSwap();
    }

    /// @dev Fallback `uniswapV3SwapCallback`.
    /// If ETH is swapped, WETH is forwarded.
    fallback() external payable virtual {
        int256 amount0Delta;
        int256 amount1Delta;
        bool ETHIn;
        bool ETHOut;
        address payer;
        address tokenIn;
        address tokenOut;
        assembly ("memory-safe") {
            amount0Delta := calldataload(0x4)
            amount1Delta := calldataload(0x24)
            ETHIn := byte(0, calldataload(0x84))
            ETHOut := byte(0, calldataload(add(0x84, 1)))
            payer := shr(96, calldataload(add(0x84, 2)))
            tokenIn := shr(96, calldataload(add(0x84, 22)))
            tokenOut := shr(96, calldataload(add(0x84, 42)))
        }
        if (amount0Delta <= 0 && amount1Delta <= 0) revert InvalidSwap();
        (address pool, bool zeroForOne) = _computePoolAddress(tokenIn, tokenOut);
        assembly ("memory-safe") {
            if iszero(eq(caller(), pool)) { revert(codesize(), 0x00) }
        }
        if (ETHIn) {
            _wrapETH(uint256(zeroForOne ? amount0Delta : amount1Delta));
        } else {
            tokenIn.safeTransferFrom(
                payer, msg.sender, uint256(zeroForOne ? amount0Delta : amount1Delta)
            );
        }
        if (ETHOut) {
            uint256 amount = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
            _unwrapETH(amount);
            payer.safeTransferETH(amount);
        }
    }

    /// @dev Computes the create2 address for given token pair.
    /// note: This process checks all available pools for price.
    function _computePoolAddress(address tokenA, address tokenB)
        internal
        view
        virtual
        returns (address pool, bool zeroForOne)
    {
        if (tokenA < tokenB) zeroForOne = true;
        else (tokenA, tokenB) = (tokenB, tokenA);
        pool = _returnPoolConstants(tokenA, tokenB);
        if (pool == address(0)) {
            pool = pairs[tokenA][tokenB];
            if (pool == address(0)) {
                address pool100 = _computePairHash(tokenA, tokenB, 100); // Lowest fee.
                address pool500 = _computePairHash(tokenA, tokenB, 500); // Lower fee.
                address pool3000 = _computePairHash(tokenA, tokenB, 3000); // Mid fee.
                address pool10000 = _computePairHash(tokenA, tokenB, 10000); // Hi fee.
                // Initialize an array to hold the liquidity information for each pool.
                SwapLiq[5] memory pools = [
                    SwapLiq(pool100, pool100.code.length != 0 ? _balanceOf(tokenA, pool100) : 0),
                    SwapLiq(pool500, pool500.code.length != 0 ? _balanceOf(tokenA, pool500) : 0),
                    SwapLiq(pool3000, pool3000.code.length != 0 ? _balanceOf(tokenA, pool3000) : 0),
                    SwapLiq(pool10000, pool10000.code.length != 0 ? _balanceOf(tokenA, pool10000) : 0),
                    SwapLiq(pool, 0) // Placeholder for top pool. This will hold outputs for comparison.
                ];
                // Iterate through the array to find the top pool with the highest liquidity in `tokenA`.
                for (uint256 i; i != 4; ++i) {
                    if (pools[i].liq > pools[4].liq) {
                        pools[4].liq = pools[i].liq;
                        pools[4].pool = pools[i].pool;
                    }
                }
                pool = pools[4].pool; // Return the top pool with likely best liquidity.
            }
        }
    }

    /// @dev Computes the create2 deployment hash for a given token pair.
    function _computePairHash(address token0, address token1, uint24 fee)
        internal
        pure
        virtual
        returns (address pool)
    {
        bytes32 salt = keccak256(abi.encode(token0, token1, fee));
        assembly ("memory-safe") {
            mstore8(0x00, 0xff) // Write the prefix.
            mstore(0x35, UNISWAP_V3_POOL_INIT_CODE_HASH)
            mstore(0x01, shl(96, UNISWAP_V3_FACTORY))
            mstore(0x15, salt)
            pool := keccak256(0x00, 0x55)
            mstore(0x35, 0) // Restore overwritten.
        }
    }

    /// @dev Wraps an `amount` of ETH to WETH and funds pool caller for swap.
    function _wrapETH(uint256 amount) internal virtual {
        assembly ("memory-safe") {
            pop(call(gas(), WETH, amount, codesize(), 0x00, codesize(), 0x00))
            mstore(0x14, caller()) // Store the `pool` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0xa9059cbb000000000000000000000000) // `transfer(address,uint256)`.
            pop(call(gas(), WETH, 0, 0x10, 0x44, codesize(), 0x00))
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    /// @dev Unwraps an `amount` of ETH from WETH for return.
    function _unwrapETH(uint256 amount) internal virtual {
        assembly ("memory-safe") {
            mstore(0x00, 0x2e1a7d4d) // `withdraw(uint256)`.
            mstore(0x20, amount) // Store the `amount` argument.
            pop(call(gas(), WETH, 0, 0x1c, 0x24, codesize(), 0x00))
        }
    }

    /// @dev Returns the amount of ERC20 `token` owned by `account`.
    function _balanceOf(address token, address account)
        internal
        view
        virtual
        returns (uint256 amount)
    {
        assembly ("memory-safe") {
            mstore(0x00, 0x70a08231000000000000000000000000) // `balanceOf(address)`.
            mstore(0x14, account) // Store the `account` argument.
            pop(staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
            amount := mload(0x20)
        }
    }

    /// @dev ETH receiver fallback.
    /// Only canonical WETH can call.
    receive() external payable virtual {
        assembly ("memory-safe") {
            if iszero(eq(caller(), WETH)) { revert(codesize(), 0x00) }
        }
    }

    /// ==================== COMMAND TRANSLATION ==================== ///

    /// @dev Translates the `intent` for send action from the solution `callData` of a standard `execute()`.
    /// note: The function selector technically doesn't need to be `execute()` but params should match.
    function translate(bytes calldata callData)
        public
        view
        virtual
        returns (string memory intent)
    {
        unchecked {
            (address target, uint256 value) = abi.decode(callData[4:68], (address, uint256));

            if (value != 0) {
                return string(
                    abi.encodePacked(
                        "send ", _toString(value / 10 ** 18), " ETH to 0x", _toAsciiString(target)
                    )
                );
            }

            // The userOp `execute()` calldata must be a call to the ERC20 `transfer()` method.
            if (bytes4(callData[132:136]) != IToken.transfer.selector) revert InvalidSelector();

            (string memory token, uint256 decimals) = _returnTokenAliasConstants(target);
            if (bytes(token).length == 0) token = aliases[target];
            if (decimals == 0) decimals = target.readDecimals(); // Sanity check.
            (target, value) = abi.decode(callData[136:], (address, uint256));

            return string(
                abi.encodePacked(
                    "send ",
                    _toString(value / 10 ** decimals),
                    " ",
                    token,
                    " to 0x",
                    _toAsciiString(target)
                )
            );
        }
    }

    /// @dev Translate ERC4337 userOp `callData` into readable send `intent`.
    function translateUserOp(UserOperation calldata userOp)
        public
        view
        virtual
        returns (string memory intent)
    {
        return translate(userOp.callData);
    }

    /// @dev Translate packed ERC4337 userOp `callData` into readable send `intent`.
    function translatePackedUserOp(PackedUserOperation calldata userOp)
        public
        view
        virtual
        returns (string memory intent)
    {
        return translate(userOp.callData);
    }

    /// ================== BALANCE & SUPPLY HELPERS ================== ///

    /// @dev Returns the balance of a named account in a named token.
    function whatIsTheBalanceOf(string calldata name, /*(bob)*/ /*in*/ string calldata token)
        public
        view
        virtual
        returns (uint256 balance, uint256 balanceAdjusted)
    {
        (, address _name,) = whatIsTheAddressOf(name);
        (address _token, uint256 decimals) =
            _returnTokenConstants(bytes32(bytes(_lowercase(token))));
        if (_token == address(0)) _token = tokens[token];
        balance = _token == ETH ? _name.balance : _token.balanceOf(_name);
        balanceAdjusted = balance / 10 ** (decimals != 0 ? decimals : _token.readDecimals());
    }

    /// @dev Returns the total supply of a named token.
    function whatIsTheTotalSupplyOf(string calldata token)
        public
        view
        virtual
        returns (uint256 supply, uint256 supplyAdjusted)
    {
        (address _token, uint256 decimals) =
            _returnTokenConstants(bytes32(bytes(_lowercase(token))));
        if (_token == address(0)) _token = tokens[token];
        assembly ("memory-safe") {
            mstore(0x00, 0x18160ddd) // `totalSupply()`.
            if iszero(staticcall(gas(), _token, 0x1c, 0x04, 0x20, 0x20)) {
                revert(codesize(), 0x00)
            }
            supply := mload(0x20)
        }
        supplyAdjusted = supply / 10 ** (decimals != 0 ? decimals : _token.readDecimals());
    }

    /// ====================== ENS VERIFICATION ====================== ///

    /// @dev Returns ENS name ownership details.
    function whatIsTheAddressOf(string memory name)
        public
        view
        virtual
        returns (address owner, address receiver, bytes32 node)
    {
        // If address length, convert.
        if (bytes(name).length == 42) {
            receiver = _toAddress(name);
        } else {
            (owner, receiver, node) = nami.whatIsTheAddressOf(name);
        }
    }

    /// ========================= GOVERNANCE ========================= ///

    /// @dev Sets a public alias tag for a given `token` address. Governed by DAO.
    function setAlias(address token, string calldata _alias) public payable virtual {
        assembly ("memory-safe") {
            if iszero(eq(caller(), DAO)) { revert(codesize(), 0x00) } // Optimized for repeat.
        }
        string memory normalized = _lowercase(_alias);
        aliases[token] = _alias;
        emit AliasSet(tokens[normalized] = token, normalized);
    }

    /// @dev Sets a public alias and ticker for a given `token` address.
    function setAliasAndTicker(address token) public payable virtual {
        string memory normalizedName = _lowercase(token.readName());
        string memory normalizedSymbol = _lowercase(token.readSymbol());
        aliases[token] = normalizedSymbol;
        emit AliasSet(tokens[normalizedName] = token, normalizedName);
        emit AliasSet(tokens[normalizedSymbol] = token, normalizedSymbol);
    }

    /// @dev Sets a public pool `pair` for swapping. Governed by DAO.
    function setPair(address tokenA, address tokenB, address pair) public payable virtual {
        assembly ("memory-safe") {
            if iszero(eq(caller(), DAO)) { revert(codesize(), 0x00) } // Optimized for repeat.
        }
        if (tokenB < tokenA) (tokenA, tokenB) = (tokenB, tokenA);
        emit PairSet(tokenA, tokenB, pairs[tokenA][tokenB] = pair);
    }

    /// @dev Sets the Arbitrum naming singleton (NAMI). Governed by DAO.
    function setNAMI(INAMI NAMI) public payable virtual {
        assembly ("memory-safe") {
            if iszero(eq(caller(), DAO)) { revert(codesize(), 0x00) } // Optimized for repeat.
        }
        nami = NAMI; // No event emitted since very infrequent if ever.
    }

    /// ===================== STRING OPERATIONS ===================== ///

    /// @dev Returns copy of string in lowercase.
    /// Modified from Solady LibString `toCase`.
    function _lowercase(string memory subject)
        internal
        pure
        virtual
        returns (string memory result)
    {
        assembly ("memory-safe") {
            let length := mload(subject)
            if length {
                result := add(mload(0x40), 0x20)
                subject := add(subject, 1)
                let flags := shl(add(70, shl(5, 0)), 0x3ffffff)
                let w := not(0)
                for { let o := length } 1 {} {
                    o := add(o, w)
                    let b := and(0xff, mload(add(subject, o)))
                    mstore8(add(result, o), xor(b, and(shr(b, flags), 0x20)))
                    if iszero(o) { break }
                }
                result := mload(0x40)
                mstore(result, length) // Store the length.
                let last := add(add(result, 0x20), length)
                mstore(last, 0) // Zeroize the slot after the string.
                mstore(0x40, add(last, 0x20)) // Allocate the memory.
            }
        }
    }

    /// @dev Extracts the first word (action) as bytes32.
    function _extraction(string memory normalizedIntent)
        internal
        pure
        virtual
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            let str := add(normalizedIntent, 0x20)
            for { let i } lt(i, 0x20) { i := add(i, 1) } {
                let char := byte(0, mload(add(str, i)))
                if eq(char, 0x20) { break }
                result := or(result, shl(sub(248, mul(i, 8)), char))
            }
        }
    }

    /// @dev Extract the key words of normalized `send` intent.
    function _extractSend(string memory normalizedIntent)
        internal
        pure
        virtual
        returns (string memory to, string memory amount, string memory token)
    {
        string[] memory parts = _split(normalizedIntent, " ");
        if (parts.length == 4) return (parts[1], parts[2], parts[3]);
        if (parts.length == 5) return (parts[4], parts[1], parts[2]);
        else revert InvalidSyntax(); // Command is not formatted.
    }

    /// @dev Extract the key words of normalized `swap` intent.
    function _extractSwap(string memory normalizedIntent)
        internal
        pure
        virtual
        returns (
            string memory amountIn,
            string memory amountOutMinimum,
            string memory tokenIn,
            string memory tokenOut
        )
    {
        string[] memory parts = _split(normalizedIntent, " ");
        if (parts.length == 5) return (parts[1], "", parts[2], parts[4]);
        if (parts.length == 6) return (parts[1], parts[4], parts[2], parts[5]);
        else revert InvalidSyntax(); // Command is not formatted.
    }

    /// @dev Split the intent into an array of words.
    function _split(string memory base, bytes1 delimiter)
        internal
        pure
        virtual
        returns (string[] memory parts)
    {
        unchecked {
            bytes memory baseBytes = bytes(base);
            uint256 count = 1;
            for (uint256 i; i != baseBytes.length; ++i) {
                if (baseBytes[i] == delimiter) {
                    ++count;
                }
            }
            parts = new string[](count);
            uint256 partIndex;
            uint256 start;
            for (uint256 i; i <= baseBytes.length; ++i) {
                if (i == baseBytes.length || baseBytes[i] == delimiter) {
                    bytes memory part = new bytes(i - start);
                    for (uint256 j = start; j != i; ++j) {
                        part[j - start] = baseBytes[j];
                    }
                    parts[partIndex] = string(part);
                    ++partIndex;
                    start = i + 1;
                }
            }
        }
    }

    /// @dev Convert string to decimalized numerical value.
    function _toUint(string memory s, uint256 decimals)
        internal
        pure
        virtual
        returns (uint256 result)
    {
        unchecked {
            bool hasDecimal;
            uint256 decimalPlaces;
            bytes memory b = bytes(s);
            for (uint256 i; i != b.length; ++i) {
                if (b[i] >= "0" && b[i] <= "9") {
                    result = result * 10 + uint8(b[i]) - 48;
                    if (hasDecimal) {
                        ++decimalPlaces;
                        if (decimalPlaces > decimals) break;
                    }
                } else if (b[i] == "." && !hasDecimal) {
                    hasDecimal = true;
                } else {
                    revert InvalidCharacter();
                }
            }
            if (decimalPlaces < decimals) {
                result *= 10 ** (decimals - decimalPlaces);
            }
        }
    }

    /// @dev Converts a hexadecimal string to its `address` representation.
    /// Modified from Stack (https://ethereum.stackexchange.com/a/156916).
    function _toAddress(string memory s) internal pure virtual returns (address addr) {
        bytes memory _bytes = _hexStringToAddress(s);
        if (_bytes.length < 21) revert InvalidSyntax();
        assembly ("memory-safe") {
            addr := div(mload(add(add(_bytes, 0x20), 1)), 0x1000000000000000000000000)
        }
    }

    /// @dev Converts a hexadecimal string into its bytes representation.
    function _hexStringToAddress(string memory s) internal pure virtual returns (bytes memory r) {
        unchecked {
            bytes memory ss = bytes(s);
            if (ss.length % 2 != 0) revert InvalidSyntax(); // Length must be even.
            r = new bytes(ss.length / 2);
            for (uint256 i; i != ss.length / 2; ++i) {
                r[i] =
                    bytes1(_fromHexChar(uint8(ss[2 * i])) * 16 + _fromHexChar(uint8(ss[2 * i + 1])));
            }
        }
    }

    /// @dev Converts a single hexadecimal character into its numerical value.
    function _fromHexChar(uint8 c) internal pure virtual returns (uint8 result) {
        unchecked {
            if (bytes1(c) >= bytes1("0") && bytes1(c) <= bytes1("9")) return c - uint8(bytes1("0"));
            if (bytes1(c) >= bytes1("a") && bytes1(c) <= bytes1("f")) {
                return 10 + c - uint8(bytes1("a"));
            }
            if (bytes1(c) >= bytes1("A") && bytes1(c) <= bytes1("F")) {
                return 10 + c - uint8(bytes1("A"));
            }
        }
    }

    /// @dev Convert an address to an ASCII string representation.
    function _toAsciiString(address x) internal pure virtual returns (string memory) {
        unchecked {
            bytes memory s = new bytes(40);
            for (uint256 i; i < 20; ++i) {
                bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
                bytes1 hi = bytes1(uint8(b) / 16);
                bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
                s[2 * i] = _char(hi);
                s[2 * i + 1] = _char(lo);
            }
            return string(s);
        }
    }

    /// @dev Convert a single byte to a character in the ASCII string.
    function _char(bytes1 b) internal pure virtual returns (bytes1 c) {
        unchecked {
            if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
            else return bytes1(uint8(b) + 0x57);
        }
    }

    /// @dev Returns the base 10 decimal representation of `value`.
    /// Modified from (https://github.com/Vectorized/solady/blob/main/src/utils/LibString.sol)
    function _toString(uint256 value) internal pure virtual returns (string memory str) {
        assembly ("memory-safe") {
            str := add(mload(0x40), 0x80)
            mstore(0x40, add(str, 0x20))
            mstore(str, 0)
            let end := str
            let w := not(0)
            for { let temp := value } 1 {} {
                str := add(str, w)
                mstore8(str, add(48, mod(temp, 10)))
                temp := div(temp, 10)
                if iszero(temp) { break }
            }
            let length := sub(end, str)
            str := sub(str, 0x20)
            mstore(str, length)
        }
    }
}

/// @dev Simple token transfer interface.
interface IToken {
    function transfer(address, uint256) external returns (bool);
}

/// @notice Simple calldata executor interface.
interface IExecutor {
    function execute(address, uint256, bytes calldata) external payable returns (bytes memory);
}

/// @dev Simple NAMI names interface for resolving L2 ENS ownership.
interface INAMI {
    function whatIsTheAddressOf(string calldata)
        external
        view
        returns (address, address, bytes32);
}

/// @dev Simple Uniswap V3 swapping interface.
interface ISwapRouter {
    function swap(address, bool, int256, uint160, bytes calldata)
        external
        returns (int256, int256);
}
