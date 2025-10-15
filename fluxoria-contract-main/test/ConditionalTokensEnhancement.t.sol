// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
 * @title ConditionalTokensEnhancementTest
 * @notice Tests for new enhancement features in ConditionalTokens contract:
 * - Multi-collateral support
 * - Mint fee mechanism
 * - Emergency pause/unpause
 * - Fee collection and withdrawal
 */
contract ConditionalTokensEnhancementTest is Test {
    ConditionalTokens public conditionalTokens;
    MockERC20 public usdc;
    MockERC20 public dai;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**6;
    uint256 marketId;
    
    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        
        // Mint tokens
        usdc.mint(owner, INITIAL_SUPPLY);
        usdc.mint(user1, INITIAL_SUPPLY);
        usdc.mint(user2, INITIAL_SUPPLY);
        
        // Mint DAI with 18 decimals
        dai.mint(user1, 1000000 * 10**18); // 1M DAI
        
        // Deploy conditional tokens
        conditionalTokens = new ConditionalTokens(address(usdc));
        
        // Create a market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        marketId = conditionalTokens.createMarket(
            "Will BTC hit $100k?",
            "BTC price prediction",
            block.timestamp + 30 days,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Approve
        vm.prank(user1);
        usdc.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(user1);
        dai.approve(address(conditionalTokens), type(uint256).max);
        
        vm.prank(user2);
        usdc.approve(address(conditionalTokens), type(uint256).max);
    }
    
    // ========== MULTI-COLLATERAL TESTS ==========
    
    function testAddCollateral() public {
        assertFalse(conditionalTokens.isCollateralSupported(address(dai)), "DAI not supported initially");
        
        conditionalTokens.addCollateral(address(dai));
        
        assertTrue(conditionalTokens.isCollateralSupported(address(dai)), "DAI should be supported");
    }
    
    function testCannotAddDuplicateCollateral() public {
        conditionalTokens.addCollateral(address(dai));
        
        vm.expectRevert("Collateral already supported");
        conditionalTokens.addCollateral(address(dai));
    }
    
    function testRemoveCollateral() public {
        conditionalTokens.addCollateral(address(dai));
        conditionalTokens.removeCollateral(address(dai));
        
        assertFalse(conditionalTokens.isCollateralSupported(address(dai)), "DAI should be removed");
    }
    
    function testCannotRemovePrimaryCollateral() public {
        vm.expectRevert("Cannot remove primary collateral");
        conditionalTokens.removeCollateral(address(usdc));
    }
    
    function testPrimaryCollateralSupportedByDefault() public {
        assertTrue(conditionalTokens.isCollateralSupported(address(usdc)), "USDC supported by default");
    }
    
    function testGetMarketCollateral() public {
        address marketCollateral = conditionalTokens.getMarketCollateral(marketId);
        assertEq(marketCollateral, address(usdc), "Market uses USDC");
    }
    
    function testSetMarketCollateral() public {
        // Add DAI support
        conditionalTokens.addCollateral(address(dai));
        
        // Create new market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        uint256 newMarketId = conditionalTokens.createMarket(
            "Test Market",
            "Test",
            block.timestamp + 30 days,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Set DAI as collateral
        conditionalTokens.setMarketCollateral(newMarketId, address(dai));
        
        address marketCollateral = conditionalTokens.getMarketCollateral(newMarketId);
        assertEq(marketCollateral, address(dai), "Market should use DAI");
    }
    
    function testCannotSetCollateralIfMarketHasBalance() public {
        // User mints tokens
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 100 * 10**6);
        
        // Add DAI
        conditionalTokens.addCollateral(address(dai));
        
        // Cannot change collateral
        vm.expectRevert("Market has existing collateral");
        conditionalTokens.setMarketCollateral(marketId, address(dai));
    }
    
    // ========== MINT FEE TESTS ==========
    
    function testMintFeeCollection() public {
        uint256 feesBefore = conditionalTokens.getCollectedFees();
        
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 1000 * 10**6);
        
        uint256 feesAfter = conditionalTokens.getCollectedFees();
        
        // Expected fee: 1000 * 0.001 = 1 USDC
        uint256 expectedFee = 1000 * 10**6 * 10 / 10000;
        assertEq(feesAfter - feesBefore, expectedFee, "Correct fee collected");
    }
    
    function testSetMintFee() public {
        uint256 newFee = 20; // 0.2%
        conditionalTokens.setMintFee(newFee);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 1000 * 10**6);
        
        uint256 balanceAfter = usdc.balanceOf(user1);
        
        // Should transfer amount + fee (0.2%)
        uint256 fee = 1000 * 10**6 * 20 / 10000;
        uint256 totalCost = 1000 * 10**6 + fee;
        assertEq(balanceBefore - balanceAfter, totalCost, "Correct amount + fee deducted");
    }
    
    function testCannotSetExcessiveMintFee() public {
        vm.expectRevert("Fee too high");
        conditionalTokens.setMintFee(101); // >1%
    }
    
    function testWithdrawFees() public {
        // Generate fees
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 10000 * 10**6);
        
        uint256 fees = conditionalTokens.getCollectedFees();
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        
        conditionalTokens.withdrawFees(owner);
        
        uint256 ownerBalanceAfter = usdc.balanceOf(owner);
        
        assertEq(conditionalTokens.getCollectedFees(), 0, "Fees withdrawn");
        assertEq(ownerBalanceAfter - ownerBalanceBefore, fees, "Owner received fees");
    }
    
    function testCannotWithdrawZeroFees() public {
        vm.expectRevert("No fees to withdraw");
        conditionalTokens.withdrawFees(owner);
    }
    
    // ========== PAUSE/UNPAUSE TESTS ==========
    
    function testPauseUnpause() public {
        conditionalTokens.pause();
        
        // Cannot mint when paused
        vm.prank(user1);
        vm.expectRevert();
        conditionalTokens.mintTokens(marketId, 0, 100 * 10**6);
        
        conditionalTokens.unpause();
        
        // Can mint after unpause
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 100 * 10**6);
        
        uint256 balance = conditionalTokens.getOutcomeBalance(marketId, user1, 0);
        assertEq(balance, 100 * 10**6, "Minting works after unpause");
    }
    
    function testCannotBurnWhenPaused() public {
        // Mint first
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, 0, 100 * 10**6);
        
        conditionalTokens.pause();
        
        // Cannot burn when paused
        vm.prank(user1);
        vm.expectRevert();
        conditionalTokens.burnTokens(marketId, 0, 100 * 10**6);
    }
    
    function testCannotCreateMarketWhenPaused() public {
        conditionalTokens.pause();
        
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.expectRevert();
        conditionalTokens.createMarket(
            "Test",
            "Test",
            block.timestamp + 1 days,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
    }
    
    // ========== INTEGRATION TESTS ==========
    
    function testCompleteFlowWithFees() public {
        uint256 mintAmount = 10000 * 10**6;
        
        vm.startPrank(user1);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        
        // Mint tokens (with fee)
        conditionalTokens.mintTokens(marketId, 0, mintAmount);
        
        uint256 balanceAfterMint = usdc.balanceOf(user1);
        
        // Should have paid amount + fee
        uint256 fee = mintAmount * 10 / 10000;
        assertEq(balanceBefore - balanceAfterMint, mintAmount + fee, "Paid amount + fee");
        
        // Burn tokens (no fee on burn)
        conditionalTokens.burnTokens(marketId, 0, mintAmount);
        
        uint256 balanceAfterBurn = usdc.balanceOf(user1);
        
        // Should get back full mint amount
        assertEq(balanceAfterBurn - balanceAfterMint, mintAmount, "Got back mint amount");
        
        // Net loss should be the fee
        assertEq(balanceBefore - balanceAfterBurn, fee, "Net loss is fee");
        
        vm.stopPrank();
        
        // Fees should be in contract
        assertEq(conditionalTokens.getCollectedFees(), fee, "Fees collected");
    }
    
    function testMultiCollateralFlow() public {
        // Add DAI support
        conditionalTokens.addCollateral(address(dai));
        
        // Create DAI market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        uint256 daiMarketId = conditionalTokens.createMarket(
            "DAI Market",
            "DAI",
            block.timestamp + 30 days,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Set DAI as collateral
        conditionalTokens.setMarketCollateral(daiMarketId, address(dai));
        
        // User1 mints with DAI
        uint256 daiBalanceBefore = dai.balanceOf(user1);
        
        vm.prank(user1);
        conditionalTokens.mintTokens(daiMarketId, 0, 1000 * 10**18); // 1000 DAI
        
        uint256 daiBalanceAfter = dai.balanceOf(user1);
        
        // Should use DAI, not USDC
        assertLt(daiBalanceAfter, daiBalanceBefore, "DAI was used");
        
        // USDC balance unchanged
        uint256 usdcBalance = usdc.balanceOf(user1);
        // Verify outcome balance
        uint256 outcomeBalance = conditionalTokens.getOutcomeBalance(daiMarketId, user1, 0);
        assertEq(outcomeBalance, 1000 * 10**18, "Got outcome tokens");
    }
    
    function testFeeAccrualOverMultipleMints() public {
        vm.startPrank(user1);
        
        // Multiple mints
        conditionalTokens.mintTokens(marketId, 0, 1000 * 10**6);
        uint256 fees1 = conditionalTokens.getCollectedFees();
        
        conditionalTokens.mintTokens(marketId, 0, 2000 * 10**6);
        uint256 fees2 = conditionalTokens.getCollectedFees();
        
        vm.stopPrank();
        
        vm.prank(user2);
        conditionalTokens.mintTokens(marketId, 0, 3000 * 10**6);
        uint256 fees3 = conditionalTokens.getCollectedFees();
        
        // Fees should accumulate
        assertGt(fees2, fees1, "Fees increased after second mint");
        assertGt(fees3, fees2, "Fees increased after third mint");
        
        // Total fees should match expected
        uint256 expectedTotal = (1000 + 2000 + 3000) * 10**6 * 10 / 10000;
        assertEq(fees3, expectedTotal, "Total fees correct");
    }
}

