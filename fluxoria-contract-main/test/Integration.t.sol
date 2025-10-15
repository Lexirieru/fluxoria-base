// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Factory} from "../src/Factory.sol";
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

contract IntegrationTest is Test {
    Factory public factory;
    MockERC20 public collateralToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**6; // 1M USDC
    uint256 public constant USER_BALANCE = 10000 * 10**6; // 10K USDC per user
    uint256 public constant MARKET_CREATION_FEE = 100 * 10**6; // 100 USDC
    
    function setUp() public {
        // Deploy mock collateral token
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens to users
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        collateralToken.mint(user3, USER_BALANCE);
        
        // Deploy factory
        vm.prank(owner);
        factory = new Factory(address(collateralToken));
        
        // Users approve factory for market creation fee
        vm.prank(user1);
        collateralToken.approve(address(factory), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(factory), USER_BALANCE);
        
        vm.prank(user3);
        collateralToken.approve(address(factory), USER_BALANCE);
    }
    
    function testCompletePredictionMarketFlow() public {
        // 1. Create market through factory
        string[] memory names = new string[](1);
        names[0] = "Will Bitcoin reach $100k by 2024?";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC-100K";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        (address market, address conditionalTokens) = factory.createMarket(
            names,
            symbols,
            expiredTime,
            outcomes
        );
        
        // 2. Get deployed contracts
        Fluxoria marketContract = Fluxoria(market);
        ConditionalTokens ctContract = ConditionalTokens(conditionalTokens);
        OrderBook orderBook = marketContract.orderBook();
        
        // 3. Users approve contracts for trading
        vm.prank(user1);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user3);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        // 4. Users trade conditional tokens directly
        uint256 tradeAmount = 1000 * 10**6; // 1000 USDC worth of tokens
        
        vm.prank(user1);
        marketContract.tradeTokens(0, 0, tradeAmount, true); // Buy "Yes" tokens
        
        vm.prank(user2);
        marketContract.tradeTokens(0, 1, tradeAmount, true); // Buy "No" tokens
        
        // Check token balances
        assertEq(marketContract.getOutcomeBalance(user1, 0), tradeAmount);
        assertEq(marketContract.getOutcomeBalance(user2, 1), tradeAmount);
        
        // 5. Users create orders on order book
        uint256 orderAmount = 100 * 10**6; // 100 tokens
        uint256 buyPrice = 0.6 * 10**6; // $0.60 per token
        uint256 sellPrice = 0.5 * 10**6; // $0.50 per token
        
        vm.prank(user1);
        uint256 buyOrderId = marketContract.createBuyOrder(0, 0, orderAmount, buyPrice);
        
        vm.prank(user2);
        uint256 sellOrderId = marketContract.createSellOrder(0, 0, orderAmount, sellPrice);
        
        // Check orders were created
        assertTrue(buyOrderId > 0);
        assertTrue(sellOrderId > 0);
        
        // 6. Users open leveraged positions
        uint256 leverage = 5;
        uint256 positionSize = 2000 * 10**6; // 2000 USDC
        uint256 collateral = positionSize / leverage; // 400 USDC
        
        vm.prank(user1);
        marketContract.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            positionSize,
            0, // marketId
            0  // outcome
        );
        
        vm.prank(user2);
        marketContract.openPosition(
            Fluxoria.PositionSide.Short,
            leverage,
            positionSize,
            0, // marketId
            1  // outcome
        );
        
        // Check positions were created
        Fluxoria.Position memory pos1 = marketContract.getUserPosition(user1);
        Fluxoria.Position memory pos2 = marketContract.getUserPosition(user2);
        
        assertEq(uint256(pos1.side), uint256(Fluxoria.PositionSide.Long));
        assertEq(uint256(pos2.side), uint256(Fluxoria.PositionSide.Short));
        assertEq(pos1.leverage, leverage);
        assertEq(pos2.leverage, leverage);
        
        // 7. Update market price to test liquidation
        vm.prank(owner);
        marketContract.updatePrice(0, 2500); // Price drops from 3000 to 2500
        
        // Check position health
        uint256 health1 = marketContract.getPositionHealth(user1);
        uint256 health2 = marketContract.getPositionHealth(user2);
        
        assertTrue(health1 < 100); // Long position health decreased
        assertTrue(health2 > 100); // Short position health increased
        
        // 8. Test liquidation
        if (marketContract.canLiquidate(user1)) {
            vm.prank(user3);
            marketContract.liquidatePosition(user1);
            
            // Check position was liquidated
            Fluxoria.Position memory liquidatedPos = marketContract.getUserPosition(user1);
            assertEq(uint256(liquidatedPos.side), uint256(Fluxoria.PositionSide.None));
        }
        
        // 9. Close remaining position
        vm.prank(user2);
        marketContract.closePosition();
        
        // Check position was closed
        Fluxoria.Position memory closedPos = marketContract.getUserPosition(user2);
        assertEq(uint256(closedPos.side), uint256(Fluxoria.PositionSide.None));
        
        // 10. Resolve market
        vm.warp(block.timestamp + 365 days + 1);
        
        vm.prank(owner);
        marketContract.resolveMarket(0, 4000); // Final price: $4000
        
        // Check market is resolved
        Fluxoria.Market memory resolvedMarket = marketContract.getMarket(0);
        assertEq(uint256(resolvedMarket.state), uint256(Fluxoria.MarketState.Resolved));
        assertTrue(resolvedMarket.isResolved);
        
        // 11. Users redeem winning tokens
        vm.prank(user1);
        ctContract.redeemTokens(0, 0); // Redeem "Yes" tokens (assuming 0 is winning outcome)
        
        // Check user received collateral
        assertTrue(collateralToken.balanceOf(user1) > 0);
    }
    
    function testOrderBookIntegration() public {
        // Create market
        (address market, address conditionalTokens) = _createTestMarket();
        Fluxoria marketContract = Fluxoria(market);
        OrderBook orderBook = marketContract.orderBook();
        
        // Users approve contracts
        vm.prank(user1);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        // Mint some tokens for trading
        vm.prank(user1);
        marketContract.tradeTokens(0, 0, 1000 * 10**6, true);
        
        vm.prank(user2);
        marketContract.tradeTokens(0, 0, 1000 * 10**6, true);
        
        // Create matching orders
        uint256 orderAmount = 100 * 10**6;
        uint256 buyPrice = 0.6 * 10**6;
        uint256 sellPrice = 0.5 * 10**6;
        
        vm.prank(user1);
        uint256 buyOrderId = marketContract.createBuyOrder(0, 0, orderAmount, buyPrice);
        
        vm.prank(user2);
        uint256 sellOrderId = marketContract.createSellOrder(0, 0, orderAmount, sellPrice);
        
        // Check orders were created and matched
        OrderBook.Order memory buyOrder = marketContract.getOrder(buyOrderId);
        OrderBook.Order memory sellOrder = marketContract.getOrder(sellOrderId);
        
        assertEq(uint256(buyOrder.status), uint256(OrderBook.OrderStatus.Filled));
        assertEq(uint256(sellOrder.status), uint256(OrderBook.OrderStatus.Filled));
        
        // Check market depth
        (uint256 bestBuyPrice, uint256 bestSellPrice) = marketContract.getMarketDepth(0, 0);
        assertTrue(bestBuyPrice > 0 || bestSellPrice > 0);
        
        // Check market orders
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = marketContract.getMarketOrders(0);
        assertTrue(buyOrders.length > 0 || sellOrders.length > 0);
    }
    
    function testLiquidationFlow() public {
        // Create market
        (address market, address conditionalTokens) = _createTestMarket();
        Fluxoria marketContract = Fluxoria(market);
        
        // Users approve contracts
        vm.prank(user1);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        // User1 opens high leverage position
        uint256 leverage = 10;
        uint256 positionSize = 1000 * 10**6;
        
        vm.prank(user1);
        marketContract.openPosition(
            Fluxoria.PositionSide.Long,
            leverage,
            positionSize,
            0, // marketId
            0  // outcome
        );
        
        // Check initial position health
        uint256 initialHealth = marketContract.getPositionHealth(user1);
        assertEq(initialHealth, 100);
        
        // Update price to trigger liquidation
        vm.prank(owner);
        marketContract.updatePrice(0, 2000); // Price drops significantly
        
        // Check position health decreased
        uint256 newHealth = marketContract.getPositionHealth(user1);
        assertTrue(newHealth < initialHealth);
        
        // Check if position can be liquidated
        bool canLiquidate = marketContract.canLiquidate(user1);
        assertTrue(canLiquidate);
        
        // Liquidate position
        vm.prank(user2);
        marketContract.liquidatePosition(user1);
        
        // Check position was liquidated
        Fluxoria.Position memory liquidatedPos = marketContract.getUserPosition(user1);
        assertEq(uint256(liquidatedPos.side), uint256(Fluxoria.PositionSide.None));
        
        // Check user received reduced collateral (due to penalty)
        assertTrue(collateralToken.balanceOf(user1) > 0);
    }
    
    function testMultipleMarkets() public {
        // Create multiple markets
        string[] memory names1 = new string[](1);
        names1[0] = "Will Bitcoin reach $100k?";
        string[] memory symbols1 = new string[](1);
        symbols1[0] = "BTC-100K";
        uint256 expiredTime1 = block.timestamp + 365 days;
        string[] memory outcomes1 = new string[](2);
        outcomes1[0] = "Yes";
        outcomes1[1] = "No";
        
        vm.prank(user1);
        (address market1, address conditionalTokens1) = factory.createMarket(
            names1,
            symbols1,
            expiredTime1,
            outcomes1
        );
        
        string[] memory names2 = new string[](1);
        names2[0] = "Will Ethereum reach $5000?";
        string[] memory symbols2 = new string[](1);
        symbols2[0] = "ETH-5000";
        uint256 expiredTime2 = block.timestamp + 200 days;
        string[] memory outcomes2 = new string[](2);
        outcomes2[0] = "Yes";
        outcomes2[1] = "No";
        
        vm.prank(user2);
        (address market2, address conditionalTokens2) = factory.createMarket(
            names2,
            symbols2,
            expiredTime2,
            outcomes2
        );
        
        // Check markets are isolated
        assertTrue(market1 != market2);
        assertTrue(conditionalTokens1 != conditionalTokens2);
        
        // Check factory mappings
        assertEq(factory.marketToConditionalTokens(market1), conditionalTokens1);
        assertEq(factory.marketToConditionalTokens(market2), conditionalTokens2);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens1), market1);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens2), market2);
        
        // Check order books are different
        Fluxoria marketContract1 = Fluxoria(market1);
        Fluxoria marketContract2 = Fluxoria(market2);
        address orderBook1 = address(marketContract1.orderBook());
        address orderBook2 = address(marketContract2.orderBook());
        
        assertTrue(orderBook1 != orderBook2);
        assertEq(factory.marketToOrderBook(market1), orderBook1);
        assertEq(factory.marketToOrderBook(market2), orderBook2);
        
        // Test trading in both markets
        vm.prank(user1);
        collateralToken.approve(address(marketContract1), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract2), USER_BALANCE);
        
        vm.prank(user1);
        marketContract1.tradeTokens(0, 0, 1000 * 10**6, true);
        
        vm.prank(user2);
        marketContract2.tradeTokens(0, 0, 1000 * 10**6, true);
        
        // Check balances are isolated
        assertEq(marketContract1.getOutcomeBalance(user1, 0), 1000 * 10**6);
        assertEq(marketContract2.getOutcomeBalance(user1, 0), 0);
        assertEq(marketContract1.getOutcomeBalance(user2, 0), 0);
        assertEq(marketContract2.getOutcomeBalance(user2, 0), 1000 * 10**6);
    }
    
    function testMarketResolution() public {
        // Create market
        (address market, address conditionalTokens) = _createTestMarket();
        Fluxoria marketContract = Fluxoria(market);
        ConditionalTokens ctContract = ConditionalTokens(conditionalTokens);
        
        // Users approve contracts
        vm.prank(user1);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        // Users trade tokens
        vm.prank(user1);
        marketContract.tradeTokens(0, 0, 1000 * 10**6, true); // Buy "Yes" tokens
        
        vm.prank(user2);
        marketContract.tradeTokens(0, 1, 1000 * 10**6, true); // Buy "No" tokens
        
        // Check token balances
        assertEq(marketContract.getOutcomeBalance(user1, 0), 1000 * 10**6);
        assertEq(marketContract.getOutcomeBalance(user2, 1), 1000 * 10**6);
        
        // Fast forward to resolution time
        vm.warp(block.timestamp + 365 days + 1);
        
        // Resolve market
        vm.prank(owner);
        marketContract.resolveMarket(0, 4000); // Final price: $4000
        
        // Check market is resolved
        Fluxoria.Market memory resolvedMarket = marketContract.getMarket(0);
        assertEq(uint256(resolvedMarket.state), uint256(Fluxoria.MarketState.Resolved));
        assertTrue(resolvedMarket.isResolved);
        
        // Users redeem winning tokens
        vm.prank(user1);
        ctContract.redeemTokens(0, 0); // Redeem "Yes" tokens
        
        vm.prank(user2);
        ctContract.redeemTokens(0, 1); // Redeem "No" tokens
        
        // Check users received collateral
        assertTrue(collateralToken.balanceOf(user1) > 0);
        assertTrue(collateralToken.balanceOf(user2) > 0);
    }
    
    function testFeeCollection() public {
        // Create market
        (address market, address conditionalTokens) = _createTestMarket();
        Fluxoria marketContract = Fluxoria(market);
        OrderBook orderBook = marketContract.orderBook();
        
        // Users approve contracts
        vm.prank(user1);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(marketContract), USER_BALANCE);
        
        // Create some trades to generate fees
        vm.prank(user1);
        marketContract.tradeTokens(0, 0, 1000 * 10**6, true);
        
        vm.prank(user2);
        marketContract.tradeTokens(0, 0, 1000 * 10**6, true);
        
        // Create orders to generate trading fees
        vm.prank(user1);
        marketContract.createBuyOrder(0, 0, 100 * 10**6, 0.6 * 10**6);
        
        vm.prank(user2);
        marketContract.createSellOrder(0, 0, 100 * 10**6, 0.5 * 10**6);
        
        // Check fees were collected
        uint256 factoryFees = factory.getTotalFees();
        uint256 orderBookFees = orderBook.getTotalFees();
        
        assertTrue(factoryFees > 0); // Market creation fee
        assertTrue(orderBookFees > 0); // Trading fees
        
        // Withdraw fees
        uint256 ownerBalance = collateralToken.balanceOf(owner);
        
        vm.prank(owner);
        factory.withdrawFees();
        
        vm.prank(owner);
        orderBook.withdrawFees();
        
        // Check owner received fees
        uint256 finalOwnerBalance = collateralToken.balanceOf(owner);
        assertTrue(finalOwnerBalance > ownerBalance);
    }
    
    function testEmergencyFunctions() public {
        // Create market
        (address market, address conditionalTokens) = _createTestMarket();
        Fluxoria marketContract = Fluxoria(market);
        
        // Test admin functions
        vm.prank(owner);
        marketContract.setLiquidationThreshold(75);
        assertEq(marketContract.liquidationThreshold(), 75);
        
        vm.prank(owner);
        marketContract.setLiquidationPenalty(10);
        assertEq(marketContract.liquidationPenalty(), 10);
        
        // Test non-owner cannot call admin functions
        vm.prank(user1);
        vm.expectRevert();
        marketContract.setLiquidationThreshold(75);
        
        // Test factory admin functions
        vm.prank(owner);
        factory.setMarketCreationFee(200 * 10**6);
        assertEq(factory.marketCreationFee(), 200 * 10**6);
        
        vm.prank(owner);
        vm.expectRevert();
        factory.withdrawFees(); // No fees to withdraw yet
    }
    
    function _createTestMarket() internal returns (address market, address conditionalTokens) {
        string[] memory names = new string[](1);
        names[0] = "Will Bitcoin reach $100k by 2024?";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC-100K";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        return factory.createMarket(names, symbols, expiredTime, outcomes);
    }
}
