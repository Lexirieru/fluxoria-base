// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token for testing
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
    
    function name() public view returns (string memory) {
        return _name;
    }
    
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    
    function decimals() public view returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
    
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
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    
    function mint(address to, uint256 amount) public {
        require(to != address(0), "ERC20: mint to the zero address");
        
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
    }
}

contract OrderBookTest is Test {
    OrderBook public orderBook;
    ConditionalTokens public conditionalTokens;
    MockERC20 public collateralToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**6; // 1M USDC
    uint256 public constant USER_BALANCE = 10000 * 10**6; // 10K USDC per user
    uint256 public constant TOKEN_AMOUNT = 1000 * 10**6; // 1000 tokens
    
    function setUp() public {
        // Deploy mock collateral token
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens to users
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        collateralToken.mint(user3, USER_BALANCE);
        
        // Deploy conditional tokens contract
        vm.prank(owner);
        conditionalTokens = new ConditionalTokens(address(collateralToken));
        
        // Set mint fee to 0 for backward compatibility
        vm.prank(owner);
        conditionalTokens.setMintFee(0);
        
        // Deploy order book
        vm.prank(owner);
        orderBook = new OrderBook(address(conditionalTokens), address(collateralToken));
        
        // Create test market
        _createTestMarket();
        
        // Users approve contracts with max allowance
        vm.prank(user1);
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user1);
        collateralToken.approve(address(orderBook), type(uint256).max);
        
        vm.prank(user2);
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user2);
        collateralToken.approve(address(orderBook), type(uint256).max);
        
        vm.prank(user3);
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user3);
        collateralToken.approve(address(orderBook), type(uint256).max);
        
        // Mint some conditional tokens for testing
        vm.prank(user1);
        conditionalTokens.mintTokens(0, 0, TOKEN_AMOUNT);
        
        vm.prank(user2);
        conditionalTokens.mintTokens(0, 0, TOKEN_AMOUNT);
        
        vm.prank(user3);
        conditionalTokens.mintTokens(0, 0, TOKEN_AMOUNT);
        
        // Approve order book to transfer outcome tokens with max allowance
        vm.prank(user1);
        conditionalTokens.approveOutcomeTokens(0, address(orderBook), 0, type(uint256).max);
        
        vm.prank(user2);
        conditionalTokens.approveOutcomeTokens(0, address(orderBook), 0, type(uint256).max);
        
        vm.prank(user3);
        conditionalTokens.approveOutcomeTokens(0, address(orderBook), 0, type(uint256).max);
    }
    
    function testInitialization() public {
        assertEq(orderBook.owner(), owner);
        assertEq(orderBook.tradingFee(), 25); // 0.25%
        assertEq(orderBook.nextOrderId(), 1);
    }
    
    function testCreateBuyOrder() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6; // 100 tokens
        uint256 maxPrice = 0.6 * 10**6; // $0.60 per token
        uint256 totalCost = (amount * maxPrice) / 10**6; // Divide by price denominator
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        vm.prank(user1);
        uint256 orderId = orderBook.createBuyOrder(marketId, outcome, amount, maxPrice);
        
        assertEq(orderId, 1);
        
        // Check order details
        OrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(order.user, user1);
        assertEq(order.marketId, marketId);
        assertEq(order.outcome, outcome);
        assertEq(uint256(order.orderType), uint256(OrderBook.OrderType.Buy));
        assertEq(order.amount, amount);
        assertEq(order.price, maxPrice);
        assertEq(uint256(order.status), uint256(OrderBook.OrderStatus.Active));
        
        // Check collateral was transferred
        assertEq(collateralToken.balanceOf(user1), initialBalance - totalCost);
        assertEq(collateralToken.balanceOf(address(orderBook)), totalCost);
        
        // Check user orders
        uint256[] memory userOrders = orderBook.getUserOrders(user1);
        assertEq(userOrders.length, 1);
        assertEq(userOrders[0], orderId);
        
        // Check market orders
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = orderBook.getMarketOrders(marketId);
        assertEq(buyOrders.length, 1);
        assertEq(sellOrders.length, 0);
        assertEq(buyOrders[0], orderId);
    }
    
    function testCreateBuyOrderFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 maxPrice = 0.6 * 10**6;
        
        // Test zero amount
        vm.prank(user1);
        vm.expectRevert("Amount must be positive");
        orderBook.createBuyOrder(marketId, outcome, 0, maxPrice);
        
        // Test zero price
        vm.prank(user1);
        vm.expectRevert("Price must be positive");
        orderBook.createBuyOrder(marketId, outcome, amount, 0);
        
        // Test insufficient collateral
        // user1 has USER_BALANCE - TOKEN_AMOUNT = 9e9 after minting
        // To make the cost exceed their balance, we need: (amount * maxPrice) / 1e6 > 9e9
        // So: amount > 9e9 * 1e6 / maxPrice = 9e9 * 1e6 / 0.6e6 = 15e9
        // But due to integer division, we need to ensure the result is > 9e9
        // Use 16e9 to ensure cost = 16e9 * 0.6 = 9.6e9 > 9e9
        uint256 largeAmount = 16 * 10**9;
        vm.prank(user1);
        vm.expectRevert("ERC20: transfer amount exceeds balance"); // MockERC20 reverts with this message
        orderBook.createBuyOrder(marketId, outcome, largeAmount, maxPrice);
    }
    
    function testCreateSellOrder() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6; // 100 tokens
        uint256 minPrice = 0.5 * 10**6; // $0.50 per token
        
        uint256 initialTokenBalance = conditionalTokens.getOutcomeBalance(marketId, user1, outcome);
        
        vm.prank(user1);
        uint256 orderId = orderBook.createSellOrder(marketId, outcome, amount, minPrice);
        
        assertEq(orderId, 1);
        
        // Check order details
        OrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(order.user, user1);
        assertEq(order.marketId, marketId);
        assertEq(order.outcome, outcome);
        assertEq(uint256(order.orderType), uint256(OrderBook.OrderType.Sell));
        assertEq(order.amount, amount);
        assertEq(order.price, minPrice);
        assertEq(uint256(order.status), uint256(OrderBook.OrderStatus.Active));
        
        // Check tokens were transferred
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user1, outcome), initialTokenBalance - amount);
        assertEq(conditionalTokens.getOutcomeBalance(marketId, address(orderBook), outcome), amount);
        
        // Check market orders
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = orderBook.getMarketOrders(marketId);
        assertEq(buyOrders.length, 0);
        assertEq(sellOrders.length, 1);
        assertEq(sellOrders[0], orderId);
    }
    
    function testCreateSellOrderFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 minPrice = 0.5 * 10**6;
        
        // Test zero amount
        vm.prank(user1);
        vm.expectRevert("Amount must be positive");
        orderBook.createSellOrder(marketId, outcome, 0, minPrice);
        
        // Test zero price
        vm.prank(user1);
        vm.expectRevert("Price must be positive");
        orderBook.createSellOrder(marketId, outcome, amount, 0);
        
        // Test insufficient tokens
        vm.prank(user1);
        vm.expectRevert("Insufficient token balance");
        orderBook.createSellOrder(marketId, outcome, TOKEN_AMOUNT + 1, minPrice);
    }
    
    function testOrderMatching() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 buyPrice = 0.6 * 10**6;
        uint256 sellPrice = 0.5 * 10**6;
        
        // Create buy order
        vm.prank(user1);
        uint256 buyOrderId = orderBook.createBuyOrder(marketId, outcome, amount, buyPrice);
        
        // Create sell order (should match)
        vm.prank(user2);
        uint256 sellOrderId = orderBook.createSellOrder(marketId, outcome, amount, sellPrice);
        
        // Check both orders are filled
        OrderBook.Order memory buyOrder = orderBook.getOrder(buyOrderId);
        OrderBook.Order memory sellOrder = orderBook.getOrder(sellOrderId);
        
        assertEq(uint256(buyOrder.status), uint256(OrderBook.OrderStatus.Filled));
        assertEq(uint256(sellOrder.status), uint256(OrderBook.OrderStatus.Filled));
        assertEq(buyOrder.filledAmount, amount);
        assertEq(sellOrder.filledAmount, amount);
        
        // Check tokens were exchanged
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user1, outcome), TOKEN_AMOUNT + amount);
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user2, outcome), TOKEN_AMOUNT - amount);
        
        // Check collateral was exchanged
        // The match price is determined by the order that was placed first (the maker)
        // In this case, the buy order at 0.6 was placed first, so the match happens at 0.6
        uint256 matchPrice = buyPrice; // Use buy price (the maker's price)
        uint256 expectedCollateral = (amount * matchPrice) / 10**6; // Divide by price denominator
        uint256 fee = (expectedCollateral * 25) / 10000; // 0.25% fee
        uint256 netCollateral = expectedCollateral - fee;
        
        // user2 started with USER_BALANCE, spent TOKEN_AMOUNT to mint tokens, and received netCollateral from the trade
        assertEq(collateralToken.balanceOf(user2), USER_BALANCE - TOKEN_AMOUNT + netCollateral);
    }
    
    function testPartialOrderFill() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 buyAmount = 100 * 10**6;
        uint256 sellAmount = 50 * 10**6; // Half the buy amount
        uint256 buyPrice = 0.6 * 10**6;
        uint256 sellPrice = 0.5 * 10**6;
        
        // Create buy order
        vm.prank(user1);
        uint256 buyOrderId = orderBook.createBuyOrder(marketId, outcome, buyAmount, buyPrice);
        
        // Create sell order (partial fill)
        vm.prank(user2);
        uint256 sellOrderId = orderBook.createSellOrder(marketId, outcome, sellAmount, sellPrice);
        
        // Check order statuses
        OrderBook.Order memory buyOrder = orderBook.getOrder(buyOrderId);
        OrderBook.Order memory sellOrder = orderBook.getOrder(sellOrderId);
        
        assertEq(uint256(buyOrder.status), uint256(OrderBook.OrderStatus.PartiallyFilled));
        assertEq(uint256(sellOrder.status), uint256(OrderBook.OrderStatus.Filled));
        assertEq(buyOrder.filledAmount, sellAmount);
        assertEq(sellOrder.filledAmount, sellAmount);
        
        // Check remaining amount
        assertEq(buyOrder.amount - buyOrder.filledAmount, buyAmount - sellAmount);
    }
    
    function testCancelOrder() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 maxPrice = 0.6 * 10**6;
        
        uint256 balanceBeforeOrder = collateralToken.balanceOf(user1);
        
        // Create buy order
        vm.prank(user1);
        uint256 orderId = orderBook.createBuyOrder(marketId, outcome, amount, maxPrice);
        
        // Cancel order
        vm.prank(user1);
        orderBook.cancelOrder(orderId);
        
        // Check order status
        OrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderBook.OrderStatus.Cancelled));
        
        // Check collateral was returned (should be back to balance before order)
        assertEq(collateralToken.balanceOf(user1), balanceBeforeOrder);
    }
    
    function testCancelOrderFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 maxPrice = 0.6 * 10**6;
        
        // Create buy order
        vm.prank(user1);
        uint256 orderId = orderBook.createBuyOrder(marketId, outcome, amount, maxPrice);
        
        // Test canceling someone else's order
        vm.prank(user2);
        vm.expectRevert("Not order owner");
        orderBook.cancelOrder(orderId);
        
        // Test canceling non-existent order
        vm.prank(user1);
        vm.expectRevert("Order not active");
        orderBook.cancelOrder(999);
    }
    
    function testMarketDepth() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        
        // Create multiple buy orders
        vm.prank(user1);
        orderBook.createBuyOrder(marketId, outcome, amount, 0.6 * 10**6);
        
        vm.prank(user2);
        orderBook.createBuyOrder(marketId, outcome, amount, 0.55 * 10**6);
        
        // Create multiple sell orders
        vm.prank(user3);
        orderBook.createSellOrder(marketId, outcome, amount, 0.65 * 10**6);
        
        // Get market depth
        (uint256 bestBuyPrice, uint256 bestSellPrice) = orderBook.getMarketDepth(marketId, outcome);
        
        assertEq(bestBuyPrice, 0.6 * 10**6); // Highest buy price
        assertEq(bestSellPrice, 0.65 * 10**6); // Lowest sell price
    }
    
    function testTradingFee() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 buyPrice = 0.6 * 10**6;
        uint256 sellPrice = 0.5 * 10**6;
        
        // Create matching orders
        vm.prank(user1);
        orderBook.createBuyOrder(marketId, outcome, amount, buyPrice);
        
        vm.prank(user2);
        orderBook.createSellOrder(marketId, outcome, amount, sellPrice);
        
        // Check trading fee was collected
        // The match price is the price of the order placed first (buy order at 0.6)
        uint256 matchPrice = buyPrice;
        uint256 expectedFee = ((amount * matchPrice) / 10**6 * 25) / 10000; // 0.25% fee, divide by price denominator first
        assertEq(collateralToken.balanceOf(address(orderBook)), expectedFee);
    }
    
    function testSetTradingFee() public {
        // Test setting new fee
        vm.prank(owner);
        orderBook.setTradingFee(50); // 0.5%
        assertEq(orderBook.tradingFee(), 50);
        
        // Test setting fee too high
        vm.prank(owner);
        vm.expectRevert("Fee too high");
        orderBook.setTradingFee(1001); // 10.01%
    }
    
    function testSetTradingFeeFails() public {
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        orderBook.setTradingFee(50);
    }
    
    function testWithdrawFees() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 buyPrice = 0.6 * 10**6;
        uint256 sellPrice = 0.5 * 10**6;
        
        // Create some trades to generate fees
        vm.prank(user1);
        orderBook.createBuyOrder(marketId, outcome, amount, buyPrice);
        
        vm.prank(user2);
        orderBook.createSellOrder(marketId, outcome, amount, sellPrice);
        
        uint256 fees = orderBook.getTotalFees();
        assertTrue(fees > 0);
        
        uint256 ownerBalance = collateralToken.balanceOf(owner);
        
        // Withdraw fees
        vm.prank(owner);
        orderBook.withdrawFees();
        
        // Check owner received fees
        assertEq(collateralToken.balanceOf(owner), ownerBalance + fees);
        assertEq(orderBook.getTotalFees(), 0);
    }
    
    function testWithdrawFeesFails() public {
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        orderBook.withdrawFees();
        
        // Test no fees to withdraw
        vm.prank(owner);
        vm.expectRevert("No fees to withdraw");
        orderBook.withdrawFees();
    }
    
    function testMultipleMarkets() public {
        // Create second market
        vm.prank(owner);
        conditionalTokens.createMarket(
            "Will Ethereum reach $5000?",
            "ETH-5000",
            block.timestamp + 365 days,
            ConditionalTokens.OutcomeType.Binary,
            _getOutcomes()
        );
        
        uint256 market1 = 0;
        uint256 market2 = 1;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        
        // Create orders in both markets
        vm.prank(user1);
        orderBook.createBuyOrder(market1, outcome, amount, 0.6 * 10**6);
        
        vm.prank(user2);
        orderBook.createBuyOrder(market2, outcome, amount, 0.7 * 10**6);
        
        // Check market isolation
        (uint256[] memory buyOrders1, uint256[] memory sellOrders1) = orderBook.getMarketOrders(market1);
        (uint256[] memory buyOrders2, uint256[] memory sellOrders2) = orderBook.getMarketOrders(market2);
        
        assertEq(buyOrders1.length, 1);
        assertEq(buyOrders2.length, 1);
        assertEq(sellOrders1.length, 0);
        assertEq(sellOrders2.length, 0);
    }
    
    function testOrderStatusTransitions() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 100 * 10**6;
        uint256 price = 0.6 * 10**6;
        
        // Create order
        vm.prank(user1);
        uint256 orderId = orderBook.createBuyOrder(marketId, outcome, amount, price);
        
        // Check initial status
        OrderBook.Order memory order = orderBook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderBook.OrderStatus.Active));
        
        // Cancel order
        vm.prank(user1);
        orderBook.cancelOrder(orderId);
        
        // Check cancelled status
        order = orderBook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderBook.OrderStatus.Cancelled));
    }
    
    function _createTestMarket() internal {
        vm.prank(owner);
        conditionalTokens.createMarket(
            "Will Bitcoin reach $100k by 2024?",
            "BTC-100K",
            block.timestamp + 365 days,
            ConditionalTokens.OutcomeType.Binary,
            _getOutcomes()
        );
    }
    
    function _getOutcomes() internal pure returns (string[] memory) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        return outcomes;
    }
}
