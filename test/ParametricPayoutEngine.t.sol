// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ParametricPayoutEngine} from "../src/ParametricPayoutEngine.sol";

contract ParametricPayoutEngineTest is Test {
    address internal alice = address(0xA11CE);

    function _baseArrays()
        internal
        pure
        returns (
            uint256[] memory windBins,
            uint256[] memory hailBins,
            uint256[] memory windPays,
            uint256[] memory hailPays
        )
    {
        windBins = new uint256[](3);
        windBins[0] = 40;
        windBins[1] = 80;
        windBins[2] = 200;

        hailBins = new uint256[](3);
        hailBins[0] = 5;
        hailBins[1] = 20;
        hailBins[2] = 100;

        windPays = new uint256[](3);
        windPays[0] = 0;
        windPays[1] = 300e6;
        windPays[2] = 900e6;

        hailPays = new uint256[](3);
        hailPays[0] = 0;
        hailPays[1] = 200e6;
        hailPays[2] = 800e6;
    }

    function _deployEngine(uint256 scaleWad, uint256 corridor, uint256 cap)
        internal
        returns (ParametricPayoutEngine engine)
    {
        (uint256[] memory windBins, uint256[] memory hailBins, uint256[] memory windPays, uint256[] memory hailPays) =
            _baseArrays();

        engine = new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, scaleWad, corridor, cap);
    }

    function test_constructor_revertsOnBadWindArrays() public {
        uint256[] memory windBins = new uint256[](1);
        uint256[] memory hailBins = new uint256[](1);
        uint256[] memory windPays = new uint256[](0);
        uint256[] memory hailPays = new uint256[](1);
        windBins[0] = 10;
        hailBins[0] = 10;
        hailPays[0] = 1;

        vm.expectRevert(bytes("bad wind arrays"));
        new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, 1e18, 0, 0);
    }

    function test_constructor_revertsOnBadHailArrays() public {
        uint256[] memory windBins = new uint256[](1);
        uint256[] memory hailBins = new uint256[](1);
        uint256[] memory windPays = new uint256[](1);
        uint256[] memory hailPays = new uint256[](0);
        windBins[0] = 10;
        hailBins[0] = 10;
        windPays[0] = 1;

        vm.expectRevert(bytes("bad hail arrays"));
        new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, 1e18, 0, 0);
    }

    function test_constructor_revertsOnUnsortedWindBins() public {
        uint256[] memory windBins = new uint256[](3);
        uint256[] memory hailBins = new uint256[](3);
        uint256[] memory windPays = new uint256[](3);
        uint256[] memory hailPays = new uint256[](3);

        windBins[0] = 10;
        windBins[1] = 9;
        windBins[2] = 20;
        hailBins[0] = 1;
        hailBins[1] = 2;
        hailBins[2] = 3;
        windPays[0] = 1;
        windPays[1] = 2;
        windPays[2] = 3;
        hailPays[0] = 1;
        hailPays[1] = 2;
        hailPays[2] = 3;

        vm.expectRevert(bytes("wind bins unsorted"));
        new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, 1e18, 0, 0);
    }

    function test_constructor_revertsOnUnsortedHailBins() public {
        uint256[] memory windBins = new uint256[](3);
        uint256[] memory hailBins = new uint256[](3);
        uint256[] memory windPays = new uint256[](3);
        uint256[] memory hailPays = new uint256[](3);

        windBins[0] = 10;
        windBins[1] = 20;
        windBins[2] = 30;
        hailBins[0] = 1;
        hailBins[1] = 1;
        hailBins[2] = 3;
        windPays[0] = 1;
        windPays[1] = 2;
        windPays[2] = 3;
        hailPays[0] = 1;
        hailPays[1] = 2;
        hailPays[2] = 3;

        vm.expectRevert(bytes("hail bins unsorted"));
        new ParametricPayoutEngine(windBins, hailBins, windPays, hailPays, 1e18, 0, 0);
    }

    function test_quoteEventPayoutBreakdown_usesFirstMatchingBinAndFallbackLastBin() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);

        (uint256 windTierA, uint256 hailTierA, uint256 rawA, uint256 scaledA, uint256 netA) =
            engine.quoteEventPayoutBreakdown(40, 20);
        assertEq(windTierA, 0);
        assertEq(hailTierA, 200e6);
        assertEq(rawA, 200e6);
        assertEq(scaledA, 200e6);
        assertEq(netA, 200e6);

        (uint256 windTierB, uint256 hailTierB, uint256 rawB, uint256 scaledB, uint256 netB) =
            engine.quoteEventPayoutBreakdown(999, 999);
        assertEq(windTierB, 900e6);
        assertEq(hailTierB, 800e6);
        assertEq(rawB, 1700e6);
        assertEq(scaledB, 1700e6);
        assertEq(netB, 1700e6);
    }

    function test_quoteEventPayoutBreakdown_appliesScaleCorridorAndCap() public {
        ParametricPayoutEngine engine = _deployEngine(2e18, 100e6, 800e6);

        (uint256 windTier, uint256 hailTier, uint256 raw, uint256 scaled, uint256 net) =
            engine.quoteEventPayoutBreakdown(100, 50);

        assertEq(windTier, 900e6);
        assertEq(hailTier, 800e6);
        assertEq(raw, 1700e6);
        assertEq(scaled, 3400e6);
        assertEq(net, 800e6);
    }

    function test_quoteEventPayoutBreakdown_zeroWhenScaledAtOrBelowCorridor() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 1700e6, 0);
        (, , , , uint256 netA) = engine.quoteEventPayoutBreakdown(100, 50);
        assertEq(netA, 0);

        engine = _deployEngine(1e18, 1800e6, 0);
        (, , , , uint256 netB) = engine.quoteEventPayoutBreakdown(100, 50);
        assertEq(netB, 0);
    }

    function test_setters_onlyOwner() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);

        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        engine.setScaleWad(2e18);

        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        engine.setCorridorDeductUSDC6(10e6);

        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        engine.setEventCapUSDC6(20e6);
    }

    function test_setters_updateValues() public {
        ParametricPayoutEngine engine = _deployEngine(1e18, 0, 0);

        engine.setScaleWad(15e17);
        engine.setCorridorDeductUSDC6(123e6);
        engine.setEventCapUSDC6(456e6);

        assertEq(engine.scaleWad(), 15e17);
        assertEq(engine.corridorDeductUSDC6(), 123e6);
        assertEq(engine.eventCapUSDC6(), 456e6);
    }
}
