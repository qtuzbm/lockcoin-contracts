// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPonsToken is ERC20 {
    address public immutable curve;
    constructor(address curve_) ERC20("Mock Pons Token", "MPT") { curve = curve_; }
    function mint(address to, uint256 amt) external { require(msg.sender == curve, "only curve"); _mint(to, amt); }
}

/// @notice 按 Pons V2 的真实几何仿真：常积曲线 + 虚拟储备 + reserved 硬顶 + 毕业关闭。
///         参数默认取链上实测值（phantom 1.68 ETH / supply 1e9 / reserved 2/7 / fee 1%）。
contract MockPonsCurve {
    MockPonsToken public immutable tokenC;
    uint256 public phantomQuote;
    uint256 public trackedQuote;   // 真实募集
    uint256 public trackedTokens;  // 曲线上的代币
    uint256 public reservedTokens;
    uint256 public feeBps = 100;
    bool public graduated;

    // 测试开关
    bool public failNextBuy;       // 模拟 Pons 侧 revert
    bool public burnAllGas;        // 模拟恶意/异常曲线把 gas 烧光

    constructor() {
        tokenC = new MockPonsToken(address(this));
        phantomQuote = 1.68 ether;
        uint256 supply = 1e9 * 1e18;
        trackedTokens = supply;
        reservedTokens = (supply * 2) / 7;
        tokenC.mint(address(this), supply);
    }

    function token() external view returns (address) { return address(tokenC); }
    function readyToGraduate() public view returns (bool) { return !graduated && trackedTokens <= reservedTokens; }
    function getReserves() external view returns (uint256, uint256) { return (phantomQuote + trackedQuote, trackedTokens); }

    function setFailNextBuy(bool v) external { failNextBuy = v; }
    function setBurnAllGas(bool v) external { burnAllGas = v; }
    function forceGraduate() external { graduated = true; }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external payable returns (uint256 tokensOut)
    {
        if (burnAllGas) { while (true) { assembly { pop(keccak256(0, 32)) } } }
        require(!failNextBuy, "MockPons: forced failure");
        require(!graduated && !readyToGraduate(), "CurveGraduated");
        require(msg.value == quoteIn && quoteIn > 0, "bad value");
        require(recipient != address(0), "zero recipient");

        uint256 eff = (quoteIn * (10_000 - feeBps)) / 10_000;
        uint256 Q = phantomQuote + trackedQuote;
        uint256 k = Q * trackedTokens;
        tokensOut = trackedTokens - (k / (Q + eff));
        if (trackedTokens - tokensOut < reservedTokens) tokensOut = trackedTokens - reservedTokens;
        require(tokensOut >= minTokensOut, "slippage");
        trackedQuote += eff;
        trackedTokens -= tokensOut;
        tokenC.transfer(recipient, tokensOut);
    }
}
