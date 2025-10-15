// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
 * @title FluxoriaEnhancementTest
 * @notice Tests for new enhancement features in Fluxoria contract:
 * - Partial position closing
 * - Insurance fund mechanism
 * - Position health monitoring
 * - Batch price updates
 * - Emergency pause/unpause
 */
contract FluxoriaEnhancementTest is Test {
    Fluxoria public fluxoria;
    MockERC20 public collateralToken;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    
    uint256 constant INITIAL_SUPPLY = 1e12; // 1M USDC (1M * 1e6)
    uint256 constant USER_BALANCE = 1e11;   // 100k USDC (100k * 1e6)
    
    function setUp() public {
        // Deploy mock USDC
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        collateralToken.mint(user3, USER_BALANCE);
        
        // Deploy Fluxoria
        string[] memory names = new string[](1);
        names[0] = "Will BTC hit $100k?";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC100k";
        
        fluxoria = new Fluxoria(names, symbols, block.timestamp + 30 days, address(collateralToken));
        
        // Fund Fluxoria with initial liquidity to support profit payouts
        collateralToken.mint(address(fluxoria), 1e12); // 1M USDC liquidity
        
        // Approve fluxoria for all users
        vm.prank(user1);
        collateralToken.approve(address(fluxoria), type(uint256).max);
        vm.prank(user2);
        collateralToken.approve(address(fluxoria), type(uint256).max);
        vm.prank(user3);
        collateralToken.approve(address(fluxoria), type(uint256).max);
    }
    
    // ========== PARTIAL POSITION CLOSING TESTS ==========
    
    function testPartialPositionClosing() public {
        // User1 opens position
        vm.startPrank(user1);
        fluxoria.openPosition(
            Fluxoria.PositionSide.Long,
            5,      // 5x leverage
            500e6,   // 500 USDC size
            0,      // Market 0
            0       // Outcome 0
        );
        
        uint256 balanceBefore = collateralToken.balanceOf(user1);
        
        // Close 50% of position
        fluxoria.closePartialPosition(50);
        
        uint256 balanceAfter = collateralToken.balanceOf(user1);
        vm.stopPrank();
        
        // Check position was partially closed
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(pos.size, 250e6, "Position size should be halved");
        assertEq(pos.collateral, 50e6, "Collateral should be halved");
        
        // Check user got collateral back
        assertGt(balanceAfter, balanceBefore, "User should receive collateral");
    }
    
    function testCannotCloseMoreThan99Percent() public {
        vm.startPrank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        vm.expectRevert("Invalid percentage");
        fluxoria.closePartialPosition(100);
        
        vm.expectRevert("Invalid percentage");
        fluxoria.closePartialPosition(101);
        vm.stopPrank();
    }
    
    function testPartialCloseAutoClosesIfBelowMinimum() public {
        vm.startPrank(user1);
        
        // Open small position
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 100e6, 0, 0);
        
        // Close 95% - remaining would be below minimum
        fluxoria.closePartialPosition(95);
        
        // Position should be fully closed
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(uint(pos.side), uint(Fluxoria.PositionSide.None), "Position should be closed");
        vm.stopPrank();
    }
    
    // ========== INSURANCE FUND TESTS ==========
    
    function testInsuranceFundCollection() public {
        uint256 fundBefore = fluxoria.getInsuranceFund();
        
        // User1 opens position
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 1000e6, 0, 0);
        
        uint256 fundAfter = fluxoria.getInsuranceFund();
        
        // Insurance fund should increase (0.1% of collateral)
        assertGt(fundAfter, fundBefore, "Insurance fund should increase");
        
        // Expected fee: (1000 / 5) * 0.001 = 0.2 USDC
        uint256 expectedIncrease = (1000e6 / 5) * 10 / 10000;
        assertEq(fundAfter - fundBefore, expectedIncrease, "Correct insurance fee");
    }
    
    function testWithdrawInsuranceFund() public {
        // Build up insurance fund
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 1000e6, 0, 0);
        
        uint256 fundAmount = fluxoria.getInsuranceFund();
        uint256 ownerBalanceBefore = collateralToken.balanceOf(owner);
        
        // Withdraw as owner
        fluxoria.withdrawInsuranceFund(fundAmount);
        
        uint256 ownerBalanceAfter = collateralToken.balanceOf(owner);
        
        assertEq(fluxoria.getInsuranceFund(), 0, "Fund should be empty");
        assertEq(ownerBalanceAfter - ownerBalanceBefore, fundAmount, "Owner should receive funds");
    }
    
    function testCannotWithdrawMoreThanInsuranceFund() public {
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 1000e6, 0, 0);
        
        uint256 fundAmount = fluxoria.getInsuranceFund();
        
        vm.expectRevert("Insufficient insurance fund");
        fluxoria.withdrawInsuranceFund(fundAmount + 1);
    }
    
    function testSetInsuranceFundFee() public {
        uint256 oldFee = 10; // 0.1%
        uint256 newFee = 20; // 0.2%
        
        fluxoria.setInsuranceFundFee(newFee);
        
        // Verify by checking market parameters
        (,, uint256 insuranceFee,,) = fluxoria.getMarketParameters();
        assertEq(insuranceFee, newFee, "Insurance fee should be updated");
    }
    
    // ========== POSITION HEALTH MONITORING TESTS ==========
    
    function testGetPositionHealth() public {
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        // At entry price, health should be 100%
        uint256 health = fluxoria.getPositionHealth(user1);
        assertEq(health, 100, "Health should be 100% at entry");
    }
    
    function testCheckPositionHealthWarning() public {
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 10, 1000e6, 0, 0);
        
        // Simulate price drop
        fluxoria.updatePrice(0, 2800); // -6.7% drop
        
        // Check health - should emit warning if < 90%
        vm.expectEmit(true, true, false, false);
        emit Fluxoria.PositionHealthWarning(user1, 0, 0, 2800);
        
        fluxoria.checkPositionHealth(user1);
    }
    
    function testGetPositionsAtRisk() public {
        // Create multiple positions
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 10, 1000e6, 0, 0);
        
        vm.prank(user2);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        // Price drop
        fluxoria.updatePrice(0, 2700); // -10% drop
        
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        
        (address[] memory atRisk, uint256[] memory healths) = fluxoria.getPositionsAtRisk(users);
        
        // User1 with 10x leverage should be at risk
        assertTrue(atRisk.length > 0, "Should have at-risk positions");
    }
    
    function testSetWarningThreshold() public {
        uint256 newThreshold = 85;
        fluxoria.setWarningThreshold(newThreshold);
        
        (,,,uint256 warningThreshold,) = fluxoria.getMarketParameters();
        assertEq(warningThreshold, newThreshold, "Warning threshold updated");
    }
    
    // ========== BATCH PRICE UPDATES TESTS ==========
    
    function testBatchUpdatePrices() public {
        // Create second market
        string[] memory names = new string[](1);
        names[0] = "Will ETH hit $5k?";
        string[] memory symbols = new string[](1);
        symbols[0] = "ETH5k";
        
        // For this test, we'll use existing market
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = 0;
        
        uint256[] memory prices = new uint256[](1);
        prices[0] = 3500;
        
        fluxoria.batchUpdatePrices(marketIds, prices);
        
        Fluxoria.Market memory market = fluxoria.getMarket(0);
        assertEq(market.currentPrice, 3500, "Price should be updated");
    }
    
    function testBatchUpdatePricesArrayMismatch() public {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = 0;
        marketIds[1] = 1;
        
        uint256[] memory prices = new uint256[](1);
        prices[0] = 3500;
        
        vm.expectRevert("Array length mismatch");
        fluxoria.batchUpdatePrices(marketIds, prices);
    }
    
    // ========== PAUSE/UNPAUSE TESTS ==========
    
    function testPauseUnpause() public {
        // Pause
        fluxoria.pause();
        
        // Try to open position when paused
        vm.prank(user1);
        vm.expectRevert();
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        // Unpause
        fluxoria.unpause();
        
        // Should work now
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        Fluxoria.Position memory pos = fluxoria.getUserPosition(user1);
        assertEq(uint(pos.side), uint(Fluxoria.PositionSide.Long), "Position opened");
    }
    
    function testCannotClosePositionWhenPaused() public {
        // Open position first
        vm.prank(user1);
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 500e6, 0, 0);
        
        // Pause
        fluxoria.pause();
        
        // Try to close
        vm.prank(user1);
        vm.expectRevert();
        fluxoria.closePosition();
    }
    
    // ========== MIN POSITION SIZE TESTS ==========
    
    function testSetMinPositionSize() public {
        uint256 newMinSize = 50e6; // 50 USDC
        fluxoria.setMinPositionSize(newMinSize);
        
        (,,,, uint256 minSize) = fluxoria.getMarketParameters();
        assertEq(minSize, newMinSize, "Min position size updated");
    }
    
    function testCannotOpenPositionBelowMinimum() public {
        // Set high minimum
        fluxoria.setMinPositionSize(100e6);
        
        vm.prank(user1);
        vm.expectRevert("Position size too small");
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 50e6, 0, 0);
    }
    
    // ========== INTEGRATION TESTS ==========
    
    function testCompleteFlowWithPartialClose() public {
        vm.startPrank(user1);
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        // 1. Open position
        fluxoria.openPosition(Fluxoria.PositionSide.Long, 5, 1000e6, 0, 0);
        
        // 2. Price goes up
        vm.stopPrank();
        fluxoria.updatePrice(0, 3500);
        vm.startPrank(user1);
        
        // 3. Check health (should be good)
        uint256 health = fluxoria.getPositionHealth(user1);
        assertGt(health, 100, "Health should be > 100%");
        
        // 4. Close 50% to take profit
        uint256 balanceBeforePartial = collateralToken.balanceOf(user1);
        fluxoria.closePartialPosition(50);
        uint256 balanceAfterPartial = collateralToken.balanceOf(user1);
        
        assertGt(balanceAfterPartial, balanceBeforePartial, "Should profit from partial close");
        
        // 5. Close remaining
        fluxoria.closePosition();
        uint256 finalBalance = collateralToken.balanceOf(user1);
        
        assertGt(finalBalance, initialBalance, "Should have overall profit");
        vm.stopPrank();
    }
}

