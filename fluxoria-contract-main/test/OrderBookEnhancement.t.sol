// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    
    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }
    
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Invalid address");
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "Insufficient balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0) && spender != address(0), "Invalid address");
        _allowances[owner][spender] = amount;
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    
    function mint(address to, uint256 amount) public {
        require(to != address(0), "Invalid address");
        _totalSupply += amount;
        unchecked { _balances[to] += amount; }
    }
}

/**
 * @title OrderBookEnhancementTest
 * @notice Tests for new enhancement features in OrderBook contract:
 * - Emergency pause/unpause functionality
 */
contract OrderBookEnhancementTest is Test {
    OrderBook public orderBook;
    ConditionalTokens public conditionalTokens;
    MockERC20 public collateralToken;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    uint256 constant INITIAL_SUPPLY = 1e12; // 1M USDC
    uint256 marketId;
    
    function setUp() public {
        // Deploy tokens
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, INITIAL_SUPPLY);
        collateralToken.mint(user2, INITIAL_SUPPLY);
        
        // Deploy conditional tokens
        conditionalTokens = new ConditionalTokens(address(collateralToken));
        conditionalTokens.setMintFee(0);
        
        // Deploy order book
        orderBook = new OrderBook(address(conditionalTokens), address(collateralToken));
        
        // Create market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        marketId = conditionalTokens.createMarket(
            "Will BTC hit $100k?",
            "BTC prediction",
            block.timestamp + 30 days,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Approve and mint tokens
        vm.prank(user1);
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user1);
        collateralToken.approve(address(orderBook), type(uint256).max);
        
        vm.prank(user2);
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user2);
        collateralToken.approve(address(orderBook), type(uint256).max);
        
        // Mint conditional tokens for both users
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 10000e6); // 10k tokens
        
        vm.prank(user2);
        conditionalTokens.mintTokens(marketId, 0, 10000e6); // 10k tokens
        
        // Approve conditional tokens for order book
        vm.prank(user1);
        conditionalTokens.approve(address(orderBook), type(uint256).max);
        
        vm.prank(user2);
        conditionalTokens.approve(address(orderBook), type(uint256).max);
    }
    
    // ========== PAUSE/UNPAUSE TESTS ==========
    
    function testPauseOrderBook() public {
        orderBook.pause();
        // Paused state is verified by trying to create orders
    }
    
    function testCannotCreateBuyOrderWhenPaused() public {
        orderBook.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        orderBook.createBuyOrder(marketId, 0, 100e6, 0.5e6);
    }
    
    function testCannotCreateSellOrderWhenPaused() public {
        orderBook.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        orderBook.createSellOrder(marketId, 0, 100e6, 0.5e6);
    }
    
    function testCannotCancelOrderWhenPaused() public {
        // Create an order first
        vm.prank(user1);
        uint256 orderId = orderBook.createSellOrder(marketId, 0, 100e6, 0.5e6);
        
        // Pause
        orderBook.pause();
        
        // Try to cancel
        vm.prank(user1);
        vm.expectRevert();
        orderBook.cancelOrder(orderId);
    }
    
    function testUnpauseOrderBook() public {
        // Pause
        orderBook.pause();
        
        // Unpause
        orderBook.unpause();
        
        // Should be able to create orders now
        vm.prank(user1);
        orderBook.createSellOrder(marketId, 0, 100e6, 0.5e6);
    }
    
    function testOnlyOwnerCanPause() public {
        vm.prank(user1);
        vm.expectRevert();
        orderBook.pause();
    }
    
    function testOnlyOwnerCanUnpause() public {
        orderBook.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        orderBook.unpause();
    }
    
    function testCompleteFlowWithPauseUnpause() public {
        // 1. Create sell order
        vm.prank(user1);
        uint256 orderId = orderBook.createSellOrder(marketId, 0, 100e6, 0.5e6);
        
        // 2. Pause
        orderBook.pause();
        
        // 3. Cannot cancel when paused
        vm.prank(user1);
        vm.expectRevert();
        orderBook.cancelOrder(orderId);
        
        // 4. Unpause
        orderBook.unpause();
        
        // 5. Can cancel now
        vm.prank(user1);
        orderBook.cancelOrder(orderId);
        
        // Verify order is cancelled
        OrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(uint(order.status), uint(OrderBook.OrderStatus.Cancelled), "Order should be cancelled");
    }
}

