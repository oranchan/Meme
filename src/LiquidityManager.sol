// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LiquidityManager
/// @notice Handles creation of the token/WETH pair and initial & subsequent liquidity additions.
/// @dev The contract deployer becomes the immutable owner responsible for initializing liquidity.
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address tokenA,
        uint256 amountADesired,
        uint256 amountAMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidityETH(
        address tokenA,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

contract LiquidityManager {
    /// @notice Address of the ERC20 token whose liquidity is managed.
    address public immutable token;
    /// @notice UniswapV2 factory address used to create or fetch the token/WETH pair.
    address public immutable factory;
    /// @notice UniswapV2 router address used for subsequent liquidity additions.
    address public immutable router;
    /// @notice Cached WETH address fetched from the router.
    address public immutable weth;
    /// @notice The pair address (token/WETH) once created or discovered.
    address public pair;
    /// @notice Flag indicating whether initial liquidity has been supplied.
    bool public initialized;
    /// @notice Contract owner (set at deployment). Can initialize liquidity.
    address public owner;
    /// @notice Tracks LP tokens minted to each address when using direct mint flow (only owner in current logic).
    mapping(address => uint256) public liquidity;

    /// @dev Restricts functions to the owner only.
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param _token The ERC20 token address.
    /// @param _factory UniswapV2 factory address.
    /// @param _router UniswapV2 router address.
    constructor(address _token, address _factory, address _router) {
        token = _token;
        factory = _factory;
        router = _router;
        weth = IUniswapV2Router02(router).WETH();
        owner = msg.sender;
    }

    /// @notice Performs the one-time initial liquidity provision (token + ETH -> token/WETH pair).
    /// @dev 1) Ensures not already initialized; 2) Creates or reuses pair; 3) Pulls tokens; 4) Wraps ETH into WETH;
    /// 5) Transfers token & WETH to pair; 6) Mints LP to owner and marks initialization complete.
    /// @param tokenAmount The amount of tokens (pre-tax) to deposit as liquidity.
    function initLiquidity(uint256 tokenAmount) external payable onlyOwner {
        require(!initialized, "already");
        require(tokenAmount > 0, "zero token");
        require(msg.value > 0, "zero eth");

        // If a pair already exists in factory, reuse it; otherwise create a new one.
        if (pair == address(0)) {
            address existing = IUniswapV2Factory(factory).getPair(token, weth);
            if (existing == address(0)) {
                pair = IUniswapV2Factory(factory).createPair(token, weth);
            } else {
                pair = existing;
            }
        }

        // 1. Pull tokens from owner (accounts for possible transfer tax via actual balance below)
        require(IERC20(token).transferFrom(msg.sender, address(this), tokenAmount), "transferFrom fail");
        uint256 actualToken = IERC20(token).balanceOf(address(this));

        // 2. Wrap ETH into WETH
        IWETH(weth).deposit{value: msg.value}();

        // 3. Transfer both assets to the pair contract
        require(IERC20(token).transfer(pair, actualToken), "token->pair fail");
        require(IWETH(weth).transfer(pair, msg.value), "weth->pair fail");

        // 4. Mint LP tokens to owner (pair updates reserves internally)
        liquidity[owner] = IUniswapV2Pair(pair).mint(owner);

        initialized = true;
    }

    /// @notice Allows any user to add more token/ETH liquidity through the router once initialized.
    /// @dev Approves router for the exact tokenAmount and calls addLiquidityETH.
    /// @param tokenAmount Exact amount of tokens the user wants to pair with attached ETH.
    function addLiquidityETH(uint256 tokenAmount) external payable {
        require(initialized, "not initialized");
        require(tokenAmount > 0, "zero token");
        require(msg.value > 0, "zero eth");
        require(IERC20(token).transferFrom(msg.sender, address(this), tokenAmount), "transferFrom fail");
        // Approve router to spend tokens for this liquidity addition
        require(IERC20(token).approve(router, tokenAmount), "approve fail");
        IUniswapV2Router02(router).addLiquidityETH{value: msg.value}(
            token, tokenAmount, tokenAmount, msg.value, msg.sender, block.timestamp + 300
        );
    }

    /// @notice Returns raw reserve data from the pair.
    /// @dev Helpful for frontends / monitoring; does not compute price ratios.
    /// @return token0 First token in pair ordering
    /// @return token1 Second token in pair ordering
    /// @return r0 Reserve of token0
    /// @return r1 Reserve of token1
    function rawReserves() external view returns (address token0, address token1, uint112 r0, uint112 r1) {
        require(pair != address(0), "Pair not created");
        token0 = IUniswapV2Pair(pair).token0();
        token1 = IUniswapV2Pair(pair).token1();
        (r0, r1,) = IUniswapV2Pair(pair).getReserves();
    }
}
