// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Fluxoria} from "../src/Fluxoria.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {OrderBook} from "../src/OrderBook.sol";
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

contract FluxoriaTest is Test {
    Fluxoria public fluxoria;
    ConditionalTokens public conditionalTokens;
    OrderBook public orderBook;
    MockERC20 public collateralToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**6; // 1M USDC
    uint256 public constant USER_BALANCE = 10000 * 10**6; // 10K USDC per user
    
    function setUp() public {
        // Deploy mock collateral token
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens to users
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        collateralToken.mint(user3, USER_BALANCE);
        
        // Deploy Fluxoria contract
        string[] memory names = new string[](1);
        names[0] = "Will Bitcoin reach $100k by 2024?";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC-100K";
        uint256 expiredTime = block.timestamp + 365 days;
        
        vm.prank(owner);
        fluxoria = new Fluxoria(names, symbols, expiredTime, address(collateralToken));
        
        // Get deployed contracts
        conditionalTokens = fluxoria.conditionalTokens();
        orderBook = fluxoria.orderBook();
        
        // Users approve contracts
        vm.prank(user1);
        collateralToken.approve(address(fluxoria), USER_BALANCE);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
        collateralToken.approve(address(orderBook), USER_BALANCE);
        assertEq(collateralToken.allowance(user1, address(fluxoria)), USER_BALANCE);

        vm.prank(user2);
        collateralToken.approve(address(fluxoria), USER_BALANCE);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
        collateralToken.approve(address(orderBook), USER_BALANCE);

        vm.prank(user3);
        collateralToken.approve(address(fluxoria), USER_BALANCE);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
        collateralToken.approve(address(orderBook), USER_BALANCE);
    }
    
    function testInitialization() public {
        assertEq(fluxoria.owner(), owner);
        assertEq(fluxoria.marketCount(), 1);
        assertEq(fluxoria.liquidationThreshold(), 80);
        assertEq(fluxoria.liquidationPenalty(), 5);
        
        // Check initial market
        Fluxoria.Market memory market = fluxoria.getMarket(0);
        assertEq(market.question, "Will Bitcoin reach $100k by 2024?");
        assertEq(market.description, "BTC-100K");
        assertEq(market.resolutionTime, block.timestamp + 365 days);
        assertEq(uint256(market.state), uint256(Fluxoria.MarketState.Active));
        assertEq(market.currentPrice, 3000);
        assertEq(market.totalVolume, 0);
        assertFalse(market.isResolved);
    }
    
    function testOpenPosition() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 5;
        uint256 size = 1000 * 10**6; // 1000 USDC
        uint256 collateral = size / leverage; // 200 USDC
        
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Check position
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(uint256(pos.side), uint256(Fluxoria.PositionSide.Long));
        assertEq(pos.size, size);
        assertEq(pos.collateral, collateral);
        assertEq(pos.entryPrice, 3000);
        assertEq(pos.leverage, leverage);
        assertEq(pos.marketId, marketId);
        assertEq(pos.outcome, outcome);
        
        // Check market volume
        Fluxoria.Market memory market = fluxoria.getMarket(marketId);
        assertEq(market.totalVolume, size);
        
        // Check user outcome balance
        assertEq(fluxoria.getOutcomeBalance(user1, outcome), collateral);
    }
    
    function testOpenPositionFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 5;
        uint256 size = 1000 * 10**6;
        
        // Test invalid side
        vm.prank(user1);
        vm.expectRevert("Invalid side");
        fluxoria.openPosition(
            Fluxoria.PositionSide.None,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Test non-existent market
        vm.prank(user1);
        vm.expectRevert("Market does not exist");
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            999,
            outcome
        );
        
        // Test invalid leverage
        vm.prank(user1);
        vm.expectRevert("Invalid leverage");
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            0,
            size,
            marketId,
            outcome
        );
        
        vm.prank(user1);
        vm.expectRevert("Invalid leverage");
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            11,
            size,
            marketId,
            outcome
        );
        
        // Test zero size
        vm.prank(user1);
        vm.expectRevert("Size must be positive");
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            0,
            marketId,
            outcome
        );
        
        // Test existing position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        vm.prank(user1);
        vm.expectRevert("Close existing position first");
        fluxoria.openPosition(
            Fluxoria.PositionSide.Short,
            leverage,
            size,
            marketId,
            outcome
        );
    }
    
    function testClosePosition() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 5;
        uint256 size = 1000 * 10**6;
        uint256 collateral = size / leverage;
        
        // Open position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        // Close position
        vm.prank(user1);
        fluxoria.closePosition();
        
        // Check position is closed
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(uint256(pos.side), uint256(Fluxoria.PositionSide.None));
        
        // Check user received collateral back
        uint256 finalBalance = collateralToken.balanceOf(user1);
        assertEq(finalBalance, initialBalance + collateral);
    }
    
    function testClosePositionFails() public {
        // Test closing non-existent position
        vm.prank(user1);
        vm.expectRevert("No open position");
        fluxoria.closePosition();
    }
    
    function testLiquidation() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 10; // High leverage for easy liquidation
        uint256 size = 1000 * 10**6;
        uint256 collateral = size / leverage; // 100 USDC
        
        // Open position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Update price to trigger liquidation (price drops significantly)
        vm.prank(owner);
        fluxoria.updatePrice(marketId, 2000); // Price drops from 3000 to 2000
        
        // Check position can be liquidated
        assertTrue(fluxoria.canLiquidate(user1));
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        // Liquidate position
        vm.prank(user2);
        fluxoria.liquidatePosition(user1);
        
        // Check position is closed
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(uint256(pos.side), uint256(Fluxoria.PositionSide.None));
        
        // Check user received reduced collateral (due to liquidation penalty)
        uint256 finalBalance = collateralToken.balanceOf(user1);
        assertTrue(finalBalance < initialBalance + collateral);
    }
    
    function testLiquidationFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 2; // Low leverage
        uint256 size = 1000 * 10**6;
        
        // Open position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Try to liquidate healthy position
        vm.prank(user2);
        vm.expectRevert("Position not eligible for liquidation");
        fluxoria.liquidatePosition(user1);
        
        // Test liquidating non-existent position
        vm.prank(user2);
        vm.expectRevert("No open position");
        fluxoria.liquidatePosition(user3);
    }
    
    function testPositionHealth() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 5;
        uint256 size = 1000 * 10**6;
        
        // Open position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Check initial health
        uint256 health = fluxoria.getPositionHealth(user1);
        assertEq(health, 100); // 100% healthy
        
        // Update price to reduce health
        vm.prank(owner);
        fluxoria.updatePrice(marketId, 2500); // Price drops
        
        health = fluxoria.getPositionHealth(user1);
        assertTrue(health < 100); // Less than 100% healthy
        
        // Check health for non-existent position
        health = fluxoria.getPositionHealth(user2);
        assertEq(health, 100); // 100% for no position
    }
    
    function testUpdatePrice() public {
        uint256 marketId = 0;
        uint256 newPrice = 3500;
        
        vm.prank(owner);
        fluxoria.updatePrice(marketId, newPrice);
        
        Fluxoria.Market memory market = fluxoria.getMarket(marketId);
        assertEq(market.currentPrice, newPrice);
    }
    
    function testUpdatePriceFails() public {
        uint256 marketId = 0;
        
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        fluxoria.updatePrice(marketId, 3500);
        
        // Test non-existent market
        vm.prank(owner);
        vm.expectRevert("Market does not exist");
        fluxoria.updatePrice(999, 3500);
        
        // Test zero price
        vm.prank(owner);
        vm.expectRevert("Price must be positive");
        fluxoria.updatePrice(marketId, 0);
    }
    
    function testResolveMarket() public {
        uint256 marketId = 0;
        uint256 finalPrice = 4000;
        
        // Fast forward to resolution time
        vm.warp(block.timestamp + 365 days + 1);
        
        vm.prank(owner);
        fluxoria.resolveMarket(marketId, finalPrice);
        
        Fluxoria.Market memory market = fluxoria.getMarket(marketId);
        assertEq(uint256(market.state), uint256(Fluxoria.MarketState.Resolved));
        assertEq(market.currentPrice, finalPrice);
        assertTrue(market.isResolved);
    }
    
    function testResolveMarketFails() public {
        uint256 marketId = 0;
        
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        fluxoria.resolveMarket(marketId, 4000);
        
        // Test before resolution time
        vm.prank(owner);
        vm.expectRevert("Market not ready for resolution");
        fluxoria.resolveMarket(marketId, 4000);
        
        // Test non-existent market
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(owner);
        vm.expectRevert("Market does not exist");
        fluxoria.resolveMarket(999, 4000);
    }
    
    function testTradeTokens() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 1000 * 10**6;
        
        // Buy tokens
        vm.prank(user1);
        fluxoria.tradeTokens(marketId, outcome, amount, true);
        
        // Check user's outcome balance
        assertEq(fluxoria.getOutcomeBalance(user1, outcome), amount);
        
        // Sell tokens
        vm.prank(user1);
        fluxoria.tradeTokens(marketId, outcome, amount, false);
        
        // Check user's outcome balance is zero
        assertEq(fluxoria.getOutcomeBalance(user1, outcome), 0);
    }
    
    function testTradeTokensFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 1000 * 10**6;
        
        // Test non-existent market
        vm.prank(user1);
        vm.expectRevert("Market does not exist");
        fluxoria.tradeTokens(999, outcome, amount, true);
        
        // Test zero amount
        vm.prank(user1);
        vm.expectRevert("Amount must be positive");
        fluxoria.tradeTokens(marketId, outcome, 0, true);
        
        // Test selling without tokens
        vm.prank(user1);
        vm.expectRevert("Insufficient token balance");
        fluxoria.tradeTokens(marketId, outcome, amount, false);
    }
    
    function testOrderBookIntegration() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 1; // 1 token
        uint256 maxPrice = 1; // 1 wei per token
        
        // Create buy order
        vm.prank(user1);
        uint256 orderId = fluxoria.createBuyOrder(marketId, outcome, amount, maxPrice);
        
        assertTrue(orderId > 0);
        
        // Get order details
        OrderBook.Order memory order = fluxoria.getOrder(orderId);
        assertEq(order.user, user1);
        assertEq(order.marketId, marketId);
        assertEq(order.outcome, outcome);
        assertEq(uint256(order.orderType), uint256(OrderBook.OrderType.Buy));
        assertEq(order.amount, amount);
        assertEq(order.price, maxPrice);
    }
    
    function testOrderBookIntegrationFails() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 amount = 1000 * 10**6;
        uint256 maxPrice = 0.6 * 10**6;
        
        // Test non-existent market
        vm.prank(user1);
        vm.expectRevert("Market does not exist");
        fluxoria.createBuyOrder(999, outcome, amount, maxPrice);
    }
    
    function testLiquidationParameters() public {
        // Test setting liquidation threshold
        vm.prank(owner);
        fluxoria.setLiquidationThreshold(75);
        assertEq(fluxoria.liquidationThreshold(), 75);
        
        // Test setting liquidation penalty
        vm.prank(owner);
        fluxoria.setLiquidationPenalty(10);
        assertEq(fluxoria.liquidationPenalty(), 10);
    }
    
    function testLiquidationParametersFails() public {
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        fluxoria.setLiquidationThreshold(75);
        
        // Test invalid threshold
        vm.prank(owner);
        vm.expectRevert("Invalid threshold");
        fluxoria.setLiquidationThreshold(0);
        
        vm.prank(owner);
        vm.expectRevert("Invalid threshold");
        fluxoria.setLiquidationThreshold(101);
        
        // Test invalid penalty
        vm.prank(owner);
        vm.expectRevert("Penalty too high");
        fluxoria.setLiquidationPenalty(25);
    }
    
    function testMultipleUsers() public {
        uint256 marketId = 0;
        uint256 outcome = 0;
        uint256 leverage = 5;
        uint256 size = 1000 * 10**6;
        
        // User1 opens Long position
        vm.prank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // User2 opens Short position
        vm.prank(user2);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Short,
            leverage,
            size,
            marketId,
            outcome
        );
        
        // Check both positions exist
        Fluxoria.Position memory pos1 = fluxoria.getUserPosition(user1);
        Fluxoria.Position memory pos2 = fluxoria.getUserPosition(user2);
        
        assertEq(uint256(pos1.side), uint256(Fluxoria.PositionSide.Long));
        assertEq(uint256(pos2.side), uint256(Fluxoria.PositionSide.Short));
        
        // Check market volume
        Fluxoria.Market memory market = fluxoria.getMarket(marketId);
        assertEq(market.totalVolume, size * 2);
    }
}
