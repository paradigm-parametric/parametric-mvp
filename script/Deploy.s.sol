// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ParametricPayoutEngine} from "../src/ParametricPayoutEngine.sol";
import {PolicyPool} from "../src/PolicyPool.sol";

contract DeployScript is Script {
    struct Config {
        address deployer;
        address owner;
        address operator;
        address usdcAddress;
        uint256 annualCapUSDC6;
        uint256 claimWindowSec;
        uint256 initialPoolFundUSDC6;
        uint256 scaleWad;
        uint256 corridorDeductUSDC6;
        uint256 eventCapUSDC6;
    }

    struct Deployment {
        PolicyPool pool;
        ParametricPayoutEngine engine;
        MockUSDC mock;
        address usdcAddress;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        Config memory cfg = _loadConfig(deployerPk);
        Deployment memory dep = _deployContracts(deployerPk, cfg);

        _maybeAcceptOperator(dep.pool, cfg.deployer, cfg.operator);
        _maybeAcceptOwner(dep.pool, cfg.deployer, cfg.owner);

        console2.log("Deployment complete");
        console2.log("PolicyPool:", address(dep.pool));
        console2.log("PayoutEngine:", address(dep.engine));
        console2.log("USDC:", dep.usdcAddress);
    }

    function _loadConfig(uint256 deployerPk) internal view returns (Config memory cfg) {
        cfg.deployer = vm.addr(deployerPk);
        cfg.owner = vm.envOr("OWNER", cfg.deployer);
        cfg.operator = vm.envOr("OPERATOR", cfg.deployer);

        cfg.usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
        cfg.annualCapUSDC6 = vm.envOr("ANNUAL_CAP_USDC6", uint256(50_000_000e6));
        cfg.claimWindowSec = vm.envOr("CLAIM_WINDOW_SEC", uint256(0));
        cfg.initialPoolFundUSDC6 = vm.envOr("INITIAL_POOL_FUND_USDC6", uint256(5_000_000e6));

        cfg.scaleWad = vm.envOr("SCALE_WAD", uint256(1e18));
        cfg.corridorDeductUSDC6 = vm.envOr("CORRIDOR_DEDUCT_USDC6", uint256(0));
        cfg.eventCapUSDC6 = vm.envOr("EVENT_CAP_USDC6", uint256(0));
    }

    function _deployContracts(uint256 deployerPk, Config memory cfg) internal returns (Deployment memory dep) {
        vm.startBroadcast(deployerPk);

        dep.usdcAddress = cfg.usdcAddress;
        if (dep.usdcAddress == address(0)) {
            dep.mock = new MockUSDC();
            dep.usdcAddress = address(dep.mock);
            console2.log("Deployed MockUSDC:", dep.usdcAddress);
        } else {
            console2.log("Using existing USDC:", dep.usdcAddress);
        }

        dep.engine = _deployEngine(cfg);
        dep.pool = new PolicyPool(dep.usdcAddress, cfg.annualCapUSDC6);
        dep.pool.setPayoutEngine(address(dep.engine));
        dep.pool.setClaimWindowSec(cfg.claimWindowSec);

        if (address(dep.mock) != address(0) && cfg.initialPoolFundUSDC6 > 0) {
            dep.mock.mint(address(dep.pool), cfg.initialPoolFundUSDC6);
            console2.log("Minted MockUSDC to pool (USDC6):", cfg.initialPoolFundUSDC6);
        }

        if (cfg.operator != cfg.deployer) {
            dep.pool.transferOperator(cfg.operator);
            console2.log("Pending operator set to:", cfg.operator);
        }

        if (cfg.owner != cfg.deployer) {
            dep.pool.transferOwnership(cfg.owner);
            console2.log("Pending owner set to:", cfg.owner);
        }

        vm.stopBroadcast();
    }

    function _deployEngine(Config memory cfg) internal returns (ParametricPayoutEngine engine) {
        (uint256[] memory windBins, uint256[] memory hailBins, uint256[] memory windPays, uint256[] memory hailPays) =
            _defaultProductConfig();

        engine = new ParametricPayoutEngine(
            windBins, hailBins, windPays, hailPays, cfg.scaleWad, cfg.corridorDeductUSDC6, cfg.eventCapUSDC6
        );
    }

    function _maybeAcceptOperator(PolicyPool pool, address deployer, address operator) internal {
        if (operator == deployer) return;

        uint256 operatorPk = vm.envOr("OPERATOR_PRIVATE_KEY", uint256(0));
        if (operatorPk == 0) {
            console2.log("Operator acceptance pending. Run acceptOperatorRole() from OPERATOR address.");
            return;
        }

        require(vm.addr(operatorPk) == operator, "OPERATOR_PRIVATE_KEY mismatch");
        vm.startBroadcast(operatorPk);
        pool.acceptOperatorRole();
        vm.stopBroadcast();
        console2.log("Operator accepted role");
    }

    function _maybeAcceptOwner(PolicyPool pool, address deployer, address owner) internal {
        if (owner == deployer) return;

        uint256 ownerPk = vm.envOr("OWNER_PRIVATE_KEY", uint256(0));
        if (ownerPk == 0) {
            console2.log("Ownership acceptance pending. Run acceptOwnership() from OWNER address.");
            return;
        }

        require(vm.addr(ownerPk) == owner, "OWNER_PRIVATE_KEY mismatch");
        vm.startBroadcast(ownerPk);
        pool.acceptOwnership();
        vm.stopBroadcast();
        console2.log("Owner accepted ownership");
    }

    function _defaultProductConfig()
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
}

