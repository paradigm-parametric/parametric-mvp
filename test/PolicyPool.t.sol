// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ParametricPayoutEngine} from "../src/ParametricPayoutEngine.sol";
import {PolicyPool} from "../src/PolicyPool.sol";

contract ToggleToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfer;
    bool public failTransferFrom;

    function setFailTransfer(bool v) external {
        failTransfer = v;
    }

    function setFailTransferFrom(bool v) external {
        failTransferFrom = v;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfer) return false;
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransferFrom) return false;
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PolicyPoolTest is Test {
    MockUSDC internal usdc;
    ParametricPayoutEngine internal engine;
    PolicyPool internal pool;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal operatorAddr = address(0x0B0B0);
    address internal newOwner = address(0x0AABB);

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        pool = new PolicyPool(address(usdc), 10_000e6);
        engine = _deployEngine(1e18, 100e6, 0);

        pool.setPayoutEngine(address(engine));

        usdc.mint(address(pool), 20_000e6);
        usdc.mint(alice, 5_000e6);
        usdc.mint(bob, 5_000e6);

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _deployEngine(uint256 scaleWad, uint256 corridor, uint256 cap)
        internal
        returns (ParametricPayoutEngine payoutEngine)
    {
        uint256[] memory windBins = new uint256[](3);
        windBins[0] = 40;
        windBins[1] = 80;
        windBins[2] = 200;

        uint256[] memory hailBins = new uint256[](3);
        hailBins[0] = 5;
        hailBins[1] = 20;
        hailBins[2] = 100;

        uint256[] memory windPays = new uint256[](3);
        windPays[0] = 0;
        windPays[1] = 300e6;
        windPays[2] = 900e6;

        uint256[] memory hailPays = new uint256[](3);
        hailPays[0] = 0;
        hailPays[1] = 200e6;
        hailPays[2] = 800e6;

        payoutEngine = new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, scaleWad, corridor, cap);
    }

    function _buyPolicyAsAlice(uint64 startDate, uint64 endDate, uint256 premiumUSDC6, uint256 limitUSDC6)
        internal
        returns (uint256 policyId)
    {
        vm.prank(alice);
        policyId = pool.buyPolicy(premiumUSDC6, limitUSDC6, startDate, endDate);
    }

    function _setOperator(address newOperator) internal {
        pool.transferOperator(newOperator);
        vm.prank(newOperator);
        pool.acceptOperatorRole();
    }

    function test_constructor_setsDefaults() public view {
        assertEq(pool.owner(), address(this));
        assertEq(pool.operator(), address(this));
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.pendingOperator(), address(0));
        assertEq(address(pool.USDC()), address(usdc));
        assertEq(pool.annualCapUSDC6(), 10_000e6);
        assertEq(pool.capYearIndex(), block.timestamp / 365 days);
        assertEq(address(pool.payoutEngine()), address(engine));
        assertEq(pool.claimWindowSec(), 0);
        assertEq(pool.totalActiveExposureUSDC6(), 0);
        assertFalse(pool.paused());
    }

    function test_constructor_revertsOnZeroUSDC() public {
        vm.expectRevert(bytes("bad usdc"));
        new PolicyPool(address(0), 1e6);
    }

    function test_poolBalanceUSDC6_reflectsTokenBalance() public view {
        assertEq(pool.poolBalanceUSDC6(), usdc.balanceOf(address(pool)));
    }

    function test_availableReservesUSDC6_reflectsExposure() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 30 days);
        _buyPolicyAsAlice(startDate, endDate, 300e6, 900e6);

        uint256 expected = usdc.balanceOf(address(pool)) - 900e6;
        assertEq(pool.availableReservesUSDC6(), expected);
    }

    function test_ownerAdmin_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("not owner"));
        pool.setAnnualCapUSDC6(1e6);
        vm.expectRevert(bytes("not owner"));
        pool.transferOwnership(newOwner);
        vm.expectRevert(bytes("not owner"));
        pool.transferOperator(operatorAddr);
        vm.expectRevert(bytes("not owner"));
        pool.setClaimWindowSec(1 days);
        vm.expectRevert(bytes("not owner"));
        pool.setPayoutEngine(address(engine));
        vm.expectRevert(bytes("not owner"));
        pool.pause();
        vm.expectRevert(bytes("not owner"));
        pool.unpause();
        vm.stopPrank();
    }

    function test_transferOwnership_flow() public {
        pool.transferOwnership(newOwner);
        assertEq(pool.pendingOwner(), newOwner);
        assertEq(pool.owner(), address(this));

        vm.prank(newOwner);
        pool.acceptOwnership();

        assertEq(pool.owner(), newOwner);
        assertEq(pool.pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsForBadOrUnexpectedAccept() public {
        vm.expectRevert(bytes("bad owner"));
        pool.transferOwnership(address(0));

        pool.transferOwnership(newOwner);
        vm.prank(alice);
        vm.expectRevert(bytes("not pending owner"));
        pool.acceptOwnership();
    }

    function test_transferOperator_flow() public {
        pool.transferOperator(operatorAddr);
        assertEq(pool.pendingOperator(), operatorAddr);
        assertEq(pool.operator(), address(this));

        vm.prank(operatorAddr);
        pool.acceptOperatorRole();

        assertEq(pool.operator(), operatorAddr);
        assertEq(pool.pendingOperator(), address(0));
    }

    function test_transferOperator_revertsForBadOrUnexpectedAccept() public {
        vm.expectRevert(bytes("bad operator"));
        pool.transferOperator(address(0));

        pool.transferOperator(operatorAddr);
        vm.prank(alice);
        vm.expectRevert(bytes("not pending operator"));
        pool.acceptOperatorRole();
    }

    function test_pauseUnpause_togglesState() public {
        pool.pause();
        assertTrue(pool.paused());

        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_depositUSDC6_transfersFromDepositor() public {
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        bool ok = pool.depositUSDC6(250e6);
        assertTrue(ok);

        assertEq(usdc.balanceOf(address(pool)), poolBefore + 250e6);
        assertEq(usdc.balanceOf(alice), aliceBefore - 250e6);
    }

    function test_depositUSDC6_revertsWhenPaused() public {
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        pool.depositUSDC6(10e6);
    }

    function test_depositUSDC6_revertsWhenTokenTransferFromReturnsFalse() public {
        ToggleToken badToken = new ToggleToken();
        PolicyPool pool2 = new PolicyPool(address(badToken), 0);
        badToken.mint(alice, 100e6);

        vm.prank(alice);
        badToken.approve(address(pool2), type(uint256).max);

        badToken.setFailTransferFrom(true);
        vm.prank(alice);
        vm.expectRevert(bytes("USDC transferFrom failed"));
        pool2.depositUSDC6(10e6);
    }

    function test_buyPolicy_storesPolicyAndCollectsPremium() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 30 days);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 aliceBefore = usdc.balanceOf(alice);

        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 300e6, 900e6);

        assertEq(policyId, 0);
        assertEq(pool.nextPolicyId(), 1);
        assertEq(usdc.balanceOf(address(pool)), poolBefore + 300e6);
        assertEq(usdc.balanceOf(alice), aliceBefore - 300e6);
        assertEq(pool.totalActiveExposureUSDC6(), 900e6);

        (address holder, uint64 start, uint64 end, uint256 limit, uint256 premium, bool active, bool paid) =
            pool.policies(policyId);
        assertEq(holder, alice);
        assertEq(start, startDate);
        assertEq(end, endDate);
        assertEq(limit, 900e6);
        assertEq(premium, 300e6);
        assertTrue(active);
        assertFalse(paid);
    }

    function test_buyPolicy_revertsOnInvalidInputs() public {
        uint64 nowTs = uint64(block.timestamp);

        vm.prank(alice);
        vm.expectRevert(bytes("bad dates"));
        pool.buyPolicy(100e6, 200e6, nowTs + 1, nowTs);

        vm.prank(alice);
        vm.expectRevert(bytes("start in past"));
        pool.buyPolicy(100e6, 200e6, nowTs - 1, nowTs + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("zero premium"));
        pool.buyPolicy(0, 200e6, nowTs, nowTs + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("zero limit"));
        pool.buyPolicy(100e6, 0, nowTs, nowTs + 1);
    }

    function test_buyPolicy_revertsWhenPaused() public {
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        pool.buyPolicy(10e6, 20e6, uint64(block.timestamp), uint64(block.timestamp + 1));
    }

    function test_buyPolicy_revertsWhenInsufficientReserves() public {
        PolicyPool pool2 = new PolicyPool(address(usdc), 0);
        pool2.setPayoutEngine(address(engine));

        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(pool2), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(bytes("insufficient reserves"));
        pool2.buyPolicy(100e6, 500e6, uint64(block.timestamp), uint64(block.timestamp + 1));
    }

    function test_buyPolicy_revertsWhenTokenTransferFromReturnsFalse() public {
        ToggleToken badToken = new ToggleToken();
        PolicyPool pool2 = new PolicyPool(address(badToken), 0);
        badToken.mint(alice, 100e6);

        vm.prank(alice);
        badToken.approve(address(pool2), type(uint256).max);

        badToken.setFailTransferFrom(true);
        vm.prank(alice);
        vm.expectRevert(bytes("USDC transferFrom failed"));
        pool2.buyPolicy(10e6, 20e6, uint64(block.timestamp), uint64(block.timestamp + 1));
    }

    function test_payOut_isDisabled() public {
        vm.expectRevert(bytes("legacy payout disabled"));
        pool.payOut(bob, 10e6);
    }

    function test_settlePolicy_revertsWhenPaused() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 10 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        vm.warp(startDate + 1 days);
        pool.pause();

        vm.expectRevert(bytes("paused"));
        pool.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_revertsWhenEngineNotSet() public {
        PolicyPool pool2 = new PolicyPool(address(usdc), 1_000e6);
        usdc.mint(address(pool2), 2_000e6);

        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(pool2), type(uint256).max);

        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 2 days);
        vm.prank(alice);
        uint256 policyId = pool2.buyPolicy(100e6, 1_000e6, startDate, endDate);

        vm.expectRevert(bytes("engine not set"));
        pool2.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_revertsForNonOperator() public {
        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 1 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        _setOperator(operatorAddr);
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        pool.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_revertsInactivePolicy() public {
        vm.expectRevert(bytes("Policy inactive"));
        pool.settlePolicy(999, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_revertsFutureEvent() public {
        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 1 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        vm.expectRevert(bytes("future event"));
        pool.settlePolicy(policyId, 100, 50, uint64(block.timestamp + 1));
    }

    function test_settlePolicy_revertsEventBeforeCoverage() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 2 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        vm.warp(startDate + 1);
        vm.expectRevert(bytes("event not covered"));
        pool.settlePolicy(policyId, 100, 50, startDate - 1);
    }

    function test_settlePolicy_revertsEventAfterCoverage() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 2 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        vm.warp(endDate + 1 days);
        vm.expectRevert(bytes("event not covered"));
        pool.settlePolicy(policyId, 100, 50, endDate + 1);
    }

    function test_settlePolicy_revertsWhenClaimWindowPassed() public {
        pool.setClaimWindowSec(1 days);

        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 5 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);
        vm.warp(startDate + 3 days);

        vm.expectRevert(bytes("claim window passed"));
        pool.settlePolicy(policyId, 100, 50, startDate + 1 days);
    }

    function test_settlePolicy_succeedsWhenWithinClaimWindow() public {
        pool.setClaimWindowSec(2 days);

        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 5 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 5_000e6);
        vm.warp(startDate + 2 days);
        uint64 eventTimestamp = uint64(block.timestamp - 12 hours);

        uint256 paid = pool.settlePolicy(policyId, 100, 50, eventTimestamp);
        assertEq(paid, 1600e6);
    }

    function test_settlePolicy_revertsWhenNoPayout() public {
        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 1 days);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, 100e6, 2_000e6);

        vm.expectRevert(bytes("no payout"));
        pool.settlePolicy(policyId, 10, 1, uint64(block.timestamp));
    }

    function test_settlePolicy_enforcesPolicyLimit_andMarksPolicyPaid() public {
        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 2 days);
        uint256 premium = 100e6;
        uint256 limit = 600e6;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, premium, limit);

        uint256 paid = pool.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
        assertEq(paid, limit);

        assertEq(usdc.balanceOf(alice), aliceBefore - premium + limit);
        assertEq(pool.paidThisYearUSDC6(), limit);
        assertEq(pool.totalActiveExposureUSDC6(), 0);

        (, , , , , bool active, bool paidFlag) = pool.policies(policyId);
        assertFalse(active);
        assertTrue(paidFlag);

        vm.expectRevert(bytes("Policy inactive"));
        pool.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_revertsWhenAnnualCapExceeded() public {
        PolicyPool pool2 = new PolicyPool(address(usdc), 500e6);
        pool2.setPayoutEngine(address(engine));
        usdc.mint(address(pool2), 5_000e6);

        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(pool2), type(uint256).max);

        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 policyId = pool2.buyPolicy(100e6, 5_000e6, startDate, endDate);

        vm.expectRevert(bytes("annual cap exceeded"));
        pool2.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
    }

    function test_settlePolicy_succeedsWhenAnnualCapDisabled() public {
        PolicyPool pool2 = new PolicyPool(address(usdc), 0);
        pool2.setPayoutEngine(address(engine));
        usdc.mint(address(pool2), 5_000e6);

        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(pool2), type(uint256).max);

        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 policyId = pool2.buyPolicy(100e6, 5_000e6, startDate, endDate);

        uint256 paid = pool2.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
        assertEq(paid, 1600e6);
        assertEq(pool2.paidThisYearUSDC6(), 1600e6);
    }

    function test_settlePolicy_allowsClaimAfterPolicyEnd_whenEventWasCovered() public {
        uint64 startDate = uint64(block.timestamp + 1 days);
        uint64 endDate = uint64(block.timestamp + 3 days);
        uint256 premium = 100e6;
        uint256 limit = 5_000e6;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 policyId = _buyPolicyAsAlice(startDate, endDate, premium, limit);

        uint64 eventTimestamp = startDate + 1 days;
        vm.warp(endDate + 2 days);
        uint256 paid = pool.settlePolicy(policyId, 100, 50, eventTimestamp);

        assertEq(paid, 1600e6);
        assertEq(usdc.balanceOf(alice), aliceBefore - premium + 1600e6);
    }

    function test_settlePolicy_resetsAnnualCounterOnNewYear() public {
        vm.warp(10 * 365 days + 1 days);

        MockUSDC usdc2 = new MockUSDC();
        PolicyPool pool2 = new PolicyPool(address(usdc2), 5_000e6);
        ParametricPayoutEngine engine2 = _deployEngine(1e18, 100e6, 0);
        pool2.setPayoutEngine(address(engine2));

        usdc2.mint(address(pool2), 20_000e6);
        usdc2.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc2.approve(address(pool2), type(uint256).max);

        uint64 startDate = uint64(block.timestamp);
        uint64 endDate = uint64(block.timestamp + 2 days);
        vm.prank(alice);
        uint256 policyId = pool2.buyPolicy(100e6, 5_000e6, startDate, endDate);

        uint256 firstPaid = pool2.settlePolicy(policyId, 100, 50, uint64(block.timestamp));
        assertEq(firstPaid, 1600e6);
        assertEq(pool2.paidThisYearUSDC6(), 1600e6);

        vm.warp(11 * 365 days + 1 days);
        usdc2.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc2.approve(address(pool2), type(uint256).max);
        vm.prank(alice);
        uint256 policyId2 = pool2.buyPolicy(100e6, 5_000e6, uint64(block.timestamp), uint64(block.timestamp + 2 days));

        uint256 secondPaid = pool2.settlePolicy(policyId2, 100, 50, uint64(block.timestamp));
        assertEq(secondPaid, 1600e6);
        assertEq(pool2.paidThisYearUSDC6(), 1600e6);
        assertEq(pool2.capYearIndex(), block.timestamp / 365 days);
    }
}

