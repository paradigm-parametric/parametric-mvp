// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPolicyPool {
    function payOut(address to, uint256 amountUSDC6) external;
}

interface IParametricPayoutEngine {
    function quoteEventPayoutBreakdown(
        uint256 windMph,
        uint256 hailTenthIn
    )
        external
        view
        returns (
            uint256 windTierUSDC6,
            uint256 hailTierUSDC6,
            uint256 rawUSDC6,
            uint256 scaledUSDC6,
            uint256 netUSDC6
        );
}

contract PolicyV2 {
    address public owner;
    address public pool;
    address public payoutEngine;

    uint256 public startDate;
    uint256 public endDate;
    uint256 public premiumUSDC6;

    bool public active;
    bool public paid;

    constructor(
        address _pool,
        address _payoutEngine,
        uint256 _startDate,
        uint256 _endDate,
        uint256 _premiumUSDC6
    ) {
        require(_pool != address(0), "bad pool");
        require(_payoutEngine != address(0), "bad engine");
        require(_endDate > _startDate, "bad dates");
        require(_premiumUSDC6 > 0, "zero premium");

        owner = msg.sender;
        pool = _pool;
        payoutEngine = _payoutEngine;
        startDate = _startDate;
        endDate = _endDate;
        premiumUSDC6 = _premiumUSDC6;
        active = true;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function triggerPayout(uint256 windMph, uint256 hailTenthIn) external onlyOwner {
        require(active, "inactive");
        require(!paid, "already paid");
        require(block.timestamp >= startDate, "not started");
        require(block.timestamp <= endDate, "expired");

        (,,,, uint256 netUSDC6) =
            IParametricPayoutEngine(payoutEngine).quoteEventPayoutBreakdown(windMph, hailTenthIn);

        require(netUSDC6 > 0, "no payout");

        paid = true;
        active = false;

        IPolicyPool(pool).payOut(owner, netUSDC6);
    }
}