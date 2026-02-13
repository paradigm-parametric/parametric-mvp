// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ParametricPayoutEngine} from "../src/ParametricPayoutEngine.sol";
import {PolicyPool} from "../src/PolicyPool.sol";
import {PolicyV2} from "../src/PolicyPoolV2.sol";

contract MockPayoutPool {
    bool public shouldRevert;
    address public lastTo;
    uint256 public lastAmount;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function payOut(address to, uint256 amountUSDC6) external {
        if (shouldRevert) revert("mock payout failed");
        lastTo = to;
        lastAmount = amountUSDC6;
    }
}

contract PolicyV2Test is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000);
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

    function _newPolicy(address poolAddr, address engineAddr, uint256 startDate, uint256 endDate)
        internal
        returns (PolicyV2 policy)
    {
        vm.prank(alice);
        policy = new PolicyV2(poolAddr, engineAddr, startDate, endDate, 100e6);
    }

    function test_constructor_revertsOnInvalidInputs() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        vm.expectRevert(bytes("bad pool"));
        new PolicyV2(address(0), address(engine), block.timestamp, block.timestamp + 1, 100e6);

        vm.expectRevert(bytes("bad engine"));
        new PolicyV2(address(0x1234), address(0), block.timestamp, block.timestamp + 1, 100e6);

        vm.expectRevert(bytes("bad dates"));
        new PolicyV2(address(0x1234), address(engine), block.timestamp + 1, block.timestamp, 100e6);

        vm.expectRevert(bytes("zero premium"));
        new PolicyV2(address(0x1234), address(engine), block.timestamp, block.timestamp + 1, 0);
    }

    function test_triggerPayout_onlyOwner() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp - 1 days, block.timestamp + 1 days);

        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        policy.triggerPayout(100, 50);
    }

    function test_triggerPayout_revertsWhenNotStarted() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp + 1 days, block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert(bytes("not started"));
        policy.triggerPayout(100, 50);
    }

    function test_triggerPayout_revertsWhenExpired() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp - 2 days, block.timestamp - 1 days);

        vm.prank(alice);
        vm.expectRevert(bytes("expired"));
        policy.triggerPayout(100, 50);
    }

    function test_triggerPayout_revertsWhenNoPayout() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp - 1 days, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(bytes("no payout"));
        policy.triggerPayout(10, 1);
    }

    function test_triggerPayout_revertsWhenPoolPayoutReverts() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        payoutPool.setShouldRevert(true);
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp - 1 days, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(bytes("mock payout failed"));
        policy.triggerPayout(100, 50);

        assertTrue(policy.active());
        assertFalse(policy.paid());
    }

    function test_triggerPayout_succeedsAgainstMockPool() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);
        MockPayoutPool payoutPool = new MockPayoutPool();
        PolicyV2 policy = _newPolicy(address(payoutPool), address(engine), block.timestamp - 1 days, block.timestamp + 1 days);

        vm.prank(alice);
        policy.triggerPayout(100, 50);

        assertEq(payoutPool.lastTo(), alice);
        assertEq(payoutPool.lastAmount(), 1700e6);
        assertFalse(policy.active());
        assertTrue(policy.paid());
    }

    function test_triggerPayout_revertsAgainstHardenedPolicyPool() public {
        vm.warp(1_700_000_000);

        MockUSDC usdc = new MockUSDC();
        PolicyPool pool = new PolicyPool(address(usdc), 0);
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);

        pool.setPayoutEngine(address(engine));
        usdc.mint(address(pool), 20_000e6);

        PolicyV2 policy = _newPolicy(address(pool), address(engine), block.timestamp - 1 days, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(bytes("legacy payout disabled"));
        policy.triggerPayout(100, 50);

        assertTrue(policy.active());
        assertFalse(policy.paid());
    }
}
