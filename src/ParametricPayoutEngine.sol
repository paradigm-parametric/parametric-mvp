// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ParametricPayoutEngine {
    // ---- product params ----
    // bins are the RIGHT edges. Example wind bins: [0,40,55,65,80,200]
    uint256[] public windBinsMph;
    uint256[] public hailBinsTenthIn;

    // payouts aligned with bins by index (same length as bins)
    uint256[] public windPayoutUSDC6;
    uint256[] public hailPayoutUSDC6;

    // scale in wad (1e18). scaled = raw * scaleWad / 1e18
    uint256 public scaleWad;

    // corridor deductible applied AFTER scaling (per event), in USDC6
    uint256 public corridorDeductUSDC6;

    // cap per event after corridor, in USDC6
    uint256 public eventCapUSDC6;

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(
        uint256[] memory _windBinsMph,
        uint256[] memory _hailBinsTenthIn,
        uint256[] memory _windPayoutUSDC6,
        uint256[] memory _hailPayoutUSDC6,
        uint256 _scaleWad,
        uint256 _corridorDeductUSDC6,
        uint256 _eventCapUSDC6
    ) {
        require(_windBinsMph.length > 0 && _windBinsMph.length == _windPayoutUSDC6.length, "bad wind arrays");
        require(_hailBinsTenthIn.length > 0 && _hailBinsTenthIn.length == _hailPayoutUSDC6.length, "bad hail arrays");
        _requireStrictlyIncreasing(_windBinsMph, "wind bins unsorted");
        _requireStrictlyIncreasing(_hailBinsTenthIn, "hail bins unsorted");
        owner = msg.sender;

        windBinsMph = _windBinsMph;
        hailBinsTenthIn = _hailBinsTenthIn;
        windPayoutUSDC6 = _windPayoutUSDC6;
        hailPayoutUSDC6 = _hailPayoutUSDC6;

        scaleWad = _scaleWad;
        corridorDeductUSDC6 = _corridorDeductUSDC6;
        eventCapUSDC6 = _eventCapUSDC6;
    }

    function setScaleWad(uint256 _scaleWad) external onlyOwner {
        scaleWad = _scaleWad;
    }

    function setCorridorDeductUSDC6(uint256 v) external onlyOwner {
        corridorDeductUSDC6 = v;
    }

    function setEventCapUSDC6(uint256 v) external onlyOwner {
        eventCapUSDC6 = v;
    }

    function quoteEventPayoutBreakdown(uint256 windMph, uint256 hailTenthIn)
        external
        view
        returns (uint256 windTierUSDC6, uint256 hailTierUSDC6, uint256 rawUSDC6, uint256 scaledUSDC6, uint256 netUSDC6)
    {
        windTierUSDC6 = _tierLookup(windMph, windBinsMph, windPayoutUSDC6);
        hailTierUSDC6 = _tierLookup(hailTenthIn, hailBinsTenthIn, hailPayoutUSDC6);

        rawUSDC6 = windTierUSDC6 + hailTierUSDC6;

        // scale (wad)
        scaledUSDC6 = (rawUSDC6 * scaleWad) / 1e18;

        // corridor deductible
        if (scaledUSDC6 <= corridorDeductUSDC6) {
            netUSDC6 = 0;
        } else {
            netUSDC6 = scaledUSDC6 - corridorDeductUSDC6;
        }

        // event cap
        if (eventCapUSDC6 > 0 && netUSDC6 > eventCapUSDC6) {
            netUSDC6 = eventCapUSDC6;
        }
    }

    function _tierLookup(uint256 x, uint256[] storage binsRight, uint256[] storage pays)
        internal
        view
        returns (uint256)
    {
        // Find first bin where x <= rightEdge
        for (uint256 i = 0; i < binsRight.length; i++) {
            if (x <= binsRight[i]) return pays[i];
        }
        // If above last edge, return last payout (or 0). We'll use last payout.
        return pays[binsRight.length - 1];
    }

    function _requireStrictlyIncreasing(uint256[] memory arr, string memory err) internal pure {
        for (uint256 i = 1; i < arr.length; i++) {
            require(arr[i] > arr[i - 1], err);
        }
    }
}
