// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IParametricPayoutEngine {
    function quoteEventPayoutBreakdown(uint256 windMph, uint256 hailTenthIn)
        external
        view
        returns (uint256 windTierUSDC6, uint256 hailTierUSDC6, uint256 rawUSDC6, uint256 scaledUSDC6, uint256 netUSDC6);
}

contract PolicyPool {
    // --- Ownership ---
    address public owner;
    address public operator;
    address public pendingOwner;
    address public pendingOperator;
    bool public paused;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // --- USDC (MockUSDC in tests) ---
    IERC20Like public USDC;
    IParametricPayoutEngine public payoutEngine;

    // --- Annual cap ---
    uint256 public annualCapUSDC6; // e.g. 50_000_000 * 1e6 for $50M if you want
    uint256 public paidThisYearUSDC6; // running total of payouts paid
    uint256 public capYearIndex; // year bucket = block.timestamp / 365 days
    uint256 public claimWindowSec; // 0 means no claim deadline after event
    uint256 public totalActiveExposureUSDC6;

    // --- Policy store ---
    struct Policy {
        address holder;
        uint64 startDate;
        uint64 endDate;
        uint256 limitUSDC6;
        uint256 premiumUSDC6;
        bool active;
        bool paid;
    }

    mapping(uint256 => Policy) public policies;
    uint256 public nextPolicyId;

    // --- Events (handy for debugging) ---
    event PolicyBought(
        uint256 indexed policyId,
        address indexed holder,
        uint256 premiumUSDC6,
        uint256 limitUSDC6,
        uint64 startDate,
        uint64 endDate
    );

    event PolicySettled(
        uint256 indexed policyId,
        address indexed holder,
        uint256 netPaidUSDC6,
        uint64 eventTimestamp,
        uint256 windMph,
        uint256 hailTenthIn
    );

    event PayoutSent(address indexed to, uint256 amountUSDC6);
    event AnnualCapUpdated(uint256 newAnnualCapUSDC6);
    event OperatorUpdated(address indexed newOperator);
    event PayoutEngineUpdated(address indexed newPayoutEngine);
    event ClaimWindowUpdated(uint256 newClaimWindowSec);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorTransferStarted(address indexed currentOperator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AnnualCounterReset(uint256 newCapYearIndex);

    // --- Constructor ---
    constructor(address usdcAddress, uint256 _annualCapUSDC6) {
        require(usdcAddress != address(0), "bad usdc");
        owner = msg.sender;
        operator = msg.sender;
        USDC = IERC20Like(usdcAddress);
        annualCapUSDC6 = _annualCapUSDC6; // can be 0 if you want "no cap" (but code below enforces only if >0)
        capYearIndex = _yearIndex(block.timestamp);
    }

    // --- Views ---
    function poolBalanceUSDC6() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function availableReservesUSDC6() external view returns (uint256) {
        uint256 bal = USDC.balanceOf(address(this));
        if (bal <= totalActiveExposureUSDC6) return 0;
        return bal - totalActiveExposureUSDC6;
    }

    // --- Admin ---
    function setAnnualCapUSDC6(uint256 _annualCapUSDC6) external onlyOwner {
        annualCapUSDC6 = _annualCapUSDC6;
        emit AnnualCapUpdated(_annualCapUSDC6);
    }

    function transferOwnership(address _pendingOwner) external onlyOwner {
        require(_pendingOwner != address(0), "bad owner");
        pendingOwner = _pendingOwner;
        emit OwnershipTransferStarted(owner, _pendingOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function transferOperator(address _pendingOperator) external onlyOwner {
        require(_pendingOperator != address(0), "bad operator");
        pendingOperator = _pendingOperator;
        emit OperatorTransferStarted(operator, _pendingOperator);
    }

    function acceptOperatorRole() external {
        require(msg.sender == pendingOperator, "not pending operator");
        address oldOperator = operator;
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorTransferred(oldOperator, operator);
        emit OperatorUpdated(operator);
    }

    function setPayoutEngine(address _payoutEngine) external onlyOwner {
        require(_payoutEngine != address(0), "bad engine");
        payoutEngine = IParametricPayoutEngine(_payoutEngine);
        emit PayoutEngineUpdated(_payoutEngine);
    }

    function setClaimWindowSec(uint256 _claimWindowSec) external onlyOwner {
        claimWindowSec = _claimWindowSec;
        emit ClaimWindowUpdated(_claimWindowSec);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- Core: fund pool (optional helper) ---
    // You can also just transfer USDC directly to the pool address; this is just convenience.
    function depositUSDC6(uint256 amountUSDC6) external whenNotPaused returns (bool) {
        bool ok = USDC.transferFrom(msg.sender, address(this), amountUSDC6);
        require(ok, "USDC transferFrom failed");
        return true;
    }

    // --- Core: buy policy ---
    function buyPolicy(uint256 premiumUSDC6, uint256 limitUSDC6, uint64 startDate, uint64 endDate)
        external
        whenNotPaused
        returns (uint256 policyId)
    {
        require(endDate > startDate, "bad dates");
        require(startDate >= block.timestamp, "start in past");
        require(premiumUSDC6 > 0, "zero premium");
        require(limitUSDC6 > 0, "zero limit");

        // Collect premium into pool
        bool ok = USDC.transferFrom(msg.sender, address(this), premiumUSDC6);
        require(ok, "USDC transferFrom failed");

        uint256 projectedExposureUSDC6 = totalActiveExposureUSDC6 + limitUSDC6;
        require(USDC.balanceOf(address(this)) >= projectedExposureUSDC6, "insufficient reserves");

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            holder: msg.sender,
            startDate: startDate,
            endDate: endDate,
            limitUSDC6: limitUSDC6,
            premiumUSDC6: premiumUSDC6,
            active: true,
            paid: false
        });
        totalActiveExposureUSDC6 = projectedExposureUSDC6;

        emit PolicyBought(policyId, msg.sender, premiumUSDC6, limitUSDC6, startDate, endDate);
        return policyId;
    }

    // --- Legacy payout function (kept because you said you have it) ---
    // NOTE: Disabled to prevent bypassing policy/accounting controls.
    function payOut(address to, uint256 amountUSDC6) external pure returns (bool) {
        to;
        amountUSDC6;
        revert("legacy payout disabled");
    }

    // --- Option 2 FIX: settle policy in one call ---
    // This is the function your Day 4 + Day 5 demo should use.
    function settlePolicy(uint256 policyId, uint256 windMph, uint256 hailTenthIn, uint64 eventTimestamp)
        external
        onlyOperator
        whenNotPaused
        returns (uint256 netPaidUSDC6)
    {
        require(address(payoutEngine) != address(0), "engine not set");

        Policy storage p = policies[policyId];

        require(p.active, "Policy inactive");
        require(!p.paid, "already paid");
        require(eventTimestamp <= block.timestamp, "future event");
        require(eventTimestamp >= p.startDate && eventTimestamp <= p.endDate, "event not covered");
        if (claimWindowSec > 0) {
            require(block.timestamp <= eventTimestamp + claimWindowSec, "claim window passed");
        }

        (,,,, uint256 netUSDC6) = payoutEngine.quoteEventPayoutBreakdown(windMph, hailTenthIn);

        require(netUSDC6 > 0, "no payout");

        // Enforce limit per policy
        if (netUSDC6 > p.limitUSDC6) {
            netUSDC6 = p.limitUSDC6;
        }

        _rollAnnualCounterIfNeeded();

        // Enforce annual cap (only if cap > 0)
        if (annualCapUSDC6 > 0) {
            require(paidThisYearUSDC6 + netUSDC6 <= annualCapUSDC6, "annual cap exceeded");
        }

        // Update accounting + policy state
        paidThisYearUSDC6 += netUSDC6;
        p.paid = true;
        p.active = false;
        totalActiveExposureUSDC6 -= p.limitUSDC6;

        // Pay from pool to policy holder
        bool ok = _payOutInternal(p.holder, netUSDC6);
        require(ok, "payout failed");

        emit PolicySettled(policyId, p.holder, netUSDC6, eventTimestamp, windMph, hailTenthIn);
        return netUSDC6;
    }

    // --- Internal payout primitive ---
    function _payOutInternal(address to, uint256 amountUSDC6) internal returns (bool) {
        require(to != address(0), "bad to");
        require(amountUSDC6 > 0, "zero payout");

        bool ok = USDC.transfer(to, amountUSDC6);
        require(ok, "USDC transfer failed");

        emit PayoutSent(to, amountUSDC6);
        return true;
    }

    function _yearIndex(uint256 ts) internal pure returns (uint256) {
        return ts / 365 days;
    }

    function _rollAnnualCounterIfNeeded() internal {
        uint256 newIdx = _yearIndex(block.timestamp);
        if (newIdx != capYearIndex) {
            capYearIndex = newIdx;
            paidThisYearUSDC6 = 0;
            emit AnnualCounterReset(newIdx);
        }
    }
}
