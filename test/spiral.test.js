const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const TICKET = ethers.parseEther("0.01");
const MULT = 10n;                              // 0.01 → 0.1
const LOCK = 0;                                // 随时可退
const V0 = TICKET * 2n;
const T0 = ethers.parseEther("1000000");
const BURN_BPS = 1500n;                        // 15% 回购销毁
const DEAD = "0x000000000000000000000000000000000000dEaD";

async function deploy({ burnBps = BURN_BPS, withPons = true, lock = LOCK } = {}) {
  let pons = null, ponsAddr = ethers.ZeroAddress;
  if (withPons) {
    pons = await (await ethers.getContractFactory("MockPonsCurve")).deploy();
    ponsAddr = await pons.getAddress();
  }
  const V = await ethers.getContractFactory("SpiralVault");
  const vault = await V.deploy("LockCoin RH", "LOCKR", TICKET, MULT, V0, T0, lock, 10, ponsAddr, burnBps);
  const share = await ethers.getContractAt("LockCoin", await vault.token());
  return { vault, share, pons };
}

async function wallets(n, fund = "1") {
  const out = [];
  for (let i = 0; i < n; i++) {
    const w = ethers.Wallet.createRandom().connect(ethers.provider);
    await network.provider.send("hardhat_setBalance", [w.address, "0x" + ethers.parseEther(fund).toString(16)]);
    out.push(w);
  }
  return out;
}

/// 每个用例结束都必须过：进 = 出 + 池 + 已销毁，且合约余额 ≥ 池
async function mustBeSolvent(vault) {
  const [ok, inAmt, outAmt, pool, burned] = await vault.solvent();
  expect(ok, `账不平: in=${inAmt} out=${outAmt} pool=${pool} burned=${burned}`).to.equal(true);
  expect(inAmt).to.equal(outAmt + pool + burned);
  expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(pool);
}

describe("SpiralVault v3 · 十倍机", function () {
  it("票价必须精确等于 0.01；直接转账拒收", async () => {
    const { vault } = await deploy();
    const [a] = await ethers.getSigners();
    await expect(vault.connect(a).buy({ value: TICKET / 2n })).to.be.revertedWithCustomError(vault, "WrongTicket");
    await expect(vault.connect(a).buy({ value: TICKET * 2n })).to.be.revertedWithCustomError(vault, "WrongTicket");
    await expect(a.sendTransaction({ to: await vault.getAddress(), value: TICKET })).to.be.revertedWithCustomError(vault, "DirectTransferRejected");
    await mustBeSolvent(vault);
  });

  it("一个钱包只能买一张", async () => {
    const { vault } = await deploy();
    const [a] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    await expect(vault.connect(a).buy({ value: TICKET })).to.be.revertedWithCustomError(vault, "OneTicketPerWallet");
    await mustBeSolvent(vault);
  });

  it("买入即锁仓：份额看得见、转不动、外人铸不了", async () => {
    const { vault, share } = await deploy();
    const [a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    const bal = await share.balanceOf(a.address);
    expect(bal).to.be.gt(0n);
    await expect(share.connect(a).transfer(b.address, bal)).to.be.revertedWithCustomError(share, "Locked");
    await share.connect(a).approve(b.address, bal);
    await expect(share.connect(b).transferFrom(a.address, b.address, bal)).to.be.revertedWithCustomError(share, "Locked");
    await expect(share.connect(a).mint(a.address, 1n)).to.be.revertedWithCustomError(share, "OnlyVault");
    await expect(share.connect(a).burn(a.address, 1n)).to.be.revertedWithCustomError(share, "OnlyVault");
    await mustBeSolvent(vault);
  });

  it("涨到 0.1 ETH 自动强卖，钱直接打回买家钱包", async () => {
    const { vault, share } = await deploy();
    const ws = await wallets(40);
    await vault.connect(ws[0]).buy({ value: TICKET });
    const balAfterBuy = await ethers.provider.getBalance(ws[0].address);
    let soldAt = -1;
    for (let i = 1; i < 40; i++) {
      const rc = await (await vault.connect(ws[i]).buy({ value: TICKET })).wait();
      const ev = rc.logs.map(l => { try { return vault.interface.parseLog(l); } catch { return null; } }).filter(e => e && e.name === "AutoSold");
      if (ev.length) { soldAt = i; expect(ev[0].args.owner).to.equal(ws[0].address); break; }
    }
    expect(soldAt).to.be.gt(0);
    const got = await ethers.provider.getBalance(ws[0].address) - balAfterBuy;
    expect(got).to.be.gte(TICKET * MULT);                    // 真收到 ≥ 0.1
    expect(await share.balanceOf(ws[0].address)).to.equal(0n); // 份额已销毁
    const info = await vault.infoOf(ws[0].address);
    expect(info.status).to.equal(2n);
    console.log(`      第 1 个买家在第 ${soldAt + 1} 张票时出场，收 ${ethers.formatEther(got)} ETH`);
    await mustBeSolvent(vault);
  });

  it("队列按持仓降序：任何时刻队首都是持仓最多的", async () => {
    const { vault } = await deploy();
    const ws = await wallets(25);
    for (const w of ws) await vault.connect(w).buy({ value: TICKET });
    const rows = await vault.queueTop(10);
    for (let i = 1; i < rows.length; i++) expect(rows[i].tokens).to.be.lte(rows[i - 1].tokens);
    expect(await vault.head()).to.equal(rows[0].idx);
    await mustBeSolvent(vault);
  });

  it("settle() 任何人可调；没人达标返回 0", async () => {
    const { vault } = await deploy();
    const [a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    expect(await vault.connect(b).settle.staticCall(10)).to.equal(0n);
  });

  it("lockPeriod=0：随时可按曲线价退出（可能亏，但绝不锁死）", async () => {
    const { vault, share } = await deploy();
    const [a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    await vault.connect(b).buy({ value: TICKET });
    const quote = await vault.quoteSell((await vault.infoOf(a.address)).tokens);
    const before = await ethers.provider.getBalance(a.address);
    const rc = await (await vault.connect(a).exit()).wait();
    const after = await ethers.provider.getBalance(a.address);
    expect(after + rc.gasUsed * rc.gasPrice - before).to.equal(quote);
    expect(await share.balanceOf(a.address)).to.equal(0n);
    await expect(vault.connect(a).exit()).to.be.revertedWithCustomError(vault, "NotLive");
    await mustBeSolvent(vault);
  });

  it("拒收合约买家：打款失败进 pending，队列不卡死，之后能 claim", async () => {
    const { vault } = await deploy();
    const rb = await (await ethers.getContractFactory("RejectingBuyer")).deploy();
    const vaddr = await vault.getAddress();
    await rb.doBuy(vaddr, { value: TICKET });
    const ws = await wallets(40);
    for (const w of ws) {
      await vault.connect(w).buy({ value: TICKET });
      if ((await vault.stats()).autoSoldCount > 0n) break;
    }
    const pend = await vault.pending(await rb.getAddress());
    expect(pend).to.be.gte(TICKET * MULT);
    expect((await vault.stats()).autoSoldCount).to.equal(1n);   // 队列推进了
    await rb.setAccept(true);
    await rb.doClaim(vaddr);
    expect(await vault.pending(await rb.getAddress())).to.equal(0n);
    await mustBeSolvent(vault);
  });

  it("150 人压力：gas 有界、恒等式守住、出场率不超过 1/10", async function () {
    this.timeout(300000);
    const { vault } = await deploy();
    const ws = await wallets(150);
    let maxGas = 0n;
    for (const w of ws) {
      const rc = await (await vault.connect(w).buy({ value: TICKET })).wait();
      if (rc.gasUsed > maxGas) maxGas = rc.gasUsed;
    }
    const s = await vault.stats();
    console.log(`      150 张票 → 出场 ${s.autoSoldCount} 人，池 ${ethers.formatEther(s.realNative)} ETH，已销毁 ${ethers.formatEther(s.totalBurnedNative)} ETH，单笔 buy 最大 gas ${maxGas}`);
    expect(s.autoSoldCount).to.be.lte(15n);
    expect(maxGas).to.be.lt(1_200_000n);
    await mustBeSolvent(vault);
  });
});

describe("SpiralVault v3 · 引擎二 · Pons 回购销毁", function () {
  it("每张票按 burnBps 拆分：15% 真的变成 Pons 币进了 0x…dEaD", async () => {
    const { vault, pons } = await deploy();
    const ponsToken = await ethers.getContractAt("MockPonsToken", await pons.token());
    const [a] = await ethers.getSigners();
    const deadBefore = await ponsToken.balanceOf(DEAD);
    const rc = await (await vault.connect(a).buy({ value: TICKET })).wait();
    const ev = rc.logs.map(l => { try { return vault.interface.parseLog(l); } catch { return null; } }).filter(e => e && e.name === "Burned");
    expect(ev.length).to.equal(1);
    const expectBurn = TICKET * BURN_BPS / 10000n;
    expect(ev[0].args.nativeSpent).to.equal(expectBurn);
    const deadAfter = await ponsToken.balanceOf(DEAD);
    expect(deadAfter - deadBefore).to.equal(ev[0].args.tokensBurned);
    expect(deadAfter).to.be.gt(0n);
    // 池子里只进了 85%
    const s = await vault.stats();
    expect(s.realNative).to.equal(TICKET - expectBurn);
    expect(s.totalIn).to.equal(TICKET);
    expect(s.totalBurnedNative).to.equal(expectBurn);
    await mustBeSolvent(vault);
  });

  it("销毁的币金库一分钱也碰不到：合约自身余额恒为 0", async () => {
    const { vault, pons } = await deploy();
    const ponsToken = await ethers.getContractAt("MockPonsToken", await pons.token());
    const ws = await wallets(10);
    for (const w of ws) await vault.connect(w).buy({ value: TICKET });
    expect(await ponsToken.balanceOf(await vault.getAddress())).to.equal(0n);
    expect(await ponsToken.balanceOf(DEAD)).to.be.gt(0n);
    await mustBeSolvent(vault);
  });

  it("Pons 侧 revert：买票照样成功，钱回落进池，不丢不卡", async () => {
    const { vault, pons } = await deploy();
    await pons.setFailNextBuy(true);
    const [a] = await ethers.getSigners();
    const rc = await (await vault.connect(a).buy({ value: TICKET })).wait();
    const skipped = rc.logs.map(l => { try { return vault.interface.parseLog(l); } catch { return null; } }).filter(e => e && e.name === "BurnSkipped");
    expect(skipped.length).to.equal(1);
    expect(skipped[0].args.nativeKept).to.equal(TICKET * BURN_BPS / 10000n);
    const s = await vault.stats();
    expect(s.realNative).to.equal(TICKET);      // 全款进池
    expect(s.totalBurnedNative).to.equal(0n);
    expect(s.burnSkipCount).to.equal(1n);
    await mustBeSolvent(vault);
  });

  it("Pons 曲线烧光 gas 也卡不死买票（BURN_GAS 护栏）", async () => {
    const { vault, pons } = await deploy();
    await pons.setBurnAllGas(true);
    const [a] = await ethers.getSigners();
    const rc = await (await vault.connect(a).buy({ value: TICKET, gasLimit: 3_000_000 })).wait();
    expect(rc.status).to.equal(1);
    expect((await vault.stats()).burnSkipCount).to.equal(1n);
    expect((await vault.stats()).realNative).to.equal(TICKET);
    await mustBeSolvent(vault);
  });

  it("Pons 毕业后回购自动停，买票继续正常", async () => {
    const { vault, pons } = await deploy();
    const [a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    expect((await vault.stats()).burnCount).to.equal(1n);
    await pons.forceGraduate();
    await vault.connect(b).buy({ value: TICKET });
    const s = await vault.stats();
    expect(s.burnCount).to.equal(1n);
    expect(s.burnSkipCount).to.equal(1n);
    expect(s.totalPositions).to.equal(2n);
    expect((await vault.spiral()).ponsGraduated).to.equal(true);
    await mustBeSolvent(vault);
  });

  it("spiral() 的数字跟链上实际一致，销毁占比会随票数单调上升", async () => {
    const { vault, pons } = await deploy();
    const ponsToken = await ethers.getContractAt("MockPonsToken", await pons.token());
    const ws = await wallets(20);
    let prevBurned = 0n, prevBps = 0n;
    for (const w of ws) {
      await vault.connect(w).buy({ value: TICKET });
      const sp = await vault.spiral();
      expect(sp.totalBurnedTokens).to.be.gte(prevBurned);   // 单调不减
      expect(sp.burnedSupplyBps).to.be.gte(prevBps);
      prevBurned = sp.totalBurnedTokens; prevBps = sp.burnedSupplyBps;
    }
    const sp = await vault.spiral();
    expect(sp.totalBurnedTokens).to.equal(await ponsToken.balanceOf(DEAD));
    expect(sp.burnPerTicket).to.equal(TICKET * BURN_BPS / 10000n);
    expect(sp.burnSink).to.equal(DEAD);
    expect(sp.ponsPrice).to.be.gt(0n);
    console.log(`      20 张票 → 销毁 ${ethers.formatEther(sp.totalBurnedNative)} ETH，买走并烧掉 ${ethers.formatUnits(sp.totalBurnedTokens, 18)} 枚 = 总供应的 ${Number(sp.burnedSupplyBps) / 100}%`);
    await mustBeSolvent(vault);
  });

  it("🔴 ticketsUntilNextPayout 的预测必须跟实际一致（带销毁时不能按票面全额推）", async function () {
    this.timeout(300000);
    const { vault } = await deploy();               // burnBps = 15%
    const ws = await wallets(80);
    // 先垫几张票，让队首有个明确的目标
    for (let i = 0; i < 5; i++) await vault.connect(ws[i]).buy({ value: TICKET });
    const predicted = Number((await vault.stats()).ticketsToNextPayout);
    expect(predicted).to.be.gt(0);
    expect(predicted).to.be.lt(200);                // NONE 的话说明推演没收敛

    // 按预测数推进，数真实出场发生在第几张
    let actual = -1;
    for (let k = 0; k < predicted + 12 && 5 + k < ws.length; k++) {
      const before = (await vault.stats()).autoSoldCount;
      await vault.connect(ws[5 + k]).buy({ value: TICKET });
      const after = (await vault.stats()).autoSoldCount;
      if (after > before) { actual = k + 1; break; }
    }
    console.log(`      预测还差 ${predicted} 张 · 实际第 ${actual} 张时出场`);
    expect(actual, "预测期内没有出场 —— 说明预测偏乐观（正是 2026-09-21 修掉的那个 bug）").to.be.gt(0);
    // 允许 ±1 张的取整误差；偏乐观（actual > predicted）是不可接受的方向
    expect(actual).to.be.lte(predicted + 1);
    await mustBeSolvent(vault);
  });

  it("参数护栏：销毁比例 >30% 部署失败；没接 Pons 却设了比例也失败", async () => {
    const pons = await (await ethers.getContractFactory("MockPonsCurve")).deploy();
    const V = await ethers.getContractFactory("SpiralVault");
    await expect(V.deploy("a", "A", TICKET, MULT, V0, T0, 0, 10, await pons.getAddress(), 3001n))
      .to.be.revertedWithCustomError(V, "BadParams");
    await expect(V.deploy("a", "A", TICKET, MULT, V0, T0, 0, 10, ethers.ZeroAddress, 1n))
      .to.be.revertedWithCustomError(V, "BadParams");
    // virtualNative 超 uint128 必须拒（否则 reserveNative*reserveToken 静默溢出，合约一部署就是砖）
    await expect(V.deploy("a", "A", TICKET, MULT, 2n ** 128n, T0, 0, 10, ethers.ZeroAddress, 0n))
      .to.be.revertedWithCustomError(V, "BadParams");
    // 不接 Pons + 0 比例 = 纯十倍机，允许
    const plain = await V.deploy("a", "A", TICKET, MULT, V0, T0, 0, 10, ethers.ZeroAddress, 0n);
    const [a] = await ethers.getSigners();
    await plain.connect(a).buy({ value: TICKET });
    expect((await plain.stats()).realNative).to.equal(TICKET);
    await mustBeSolvent(plain);
  });

  it("销毁的代价是诚实的：同样票数下，带销毁的出场比不带销毁的慢", async function () {
    this.timeout(300000);
    const runTo = async (burnBps) => {
      const { vault } = await deploy({ burnBps });
      const ws = await wallets(60);
      for (const w of ws) await vault.connect(w).buy({ value: TICKET });
      await mustBeSolvent(vault);
      return (await vault.stats()).autoSoldCount;
    };
    const noBurn = await runTo(0n);
    const withBurn = await runTo(BURN_BPS);
    console.log(`      60 张票：不销毁出场 ${noBurn} 人 · 销毁15%出场 ${withBurn} 人（代价如实体现，没有藏）`);
    expect(withBurn).to.be.lte(noBurn);
  });
});

describe("SpiralVault v3 · 对抗审计第二轮补的两条", function () {
  it("🔴 buyMin 滑点下限：拿不到下限份额就整笔回滚，老签名行为不变", async () => {
    const { vault } = await deploy();
    const [a, b] = await ethers.getSigners();
    // 同样一张票，先买的人拿得多；后买的人按前者的份额设下限必然拿不到
    await vault.connect(a).buy({ value: TICKET });
    const first = (await vault.positions(0)).tokens;
    await expect(vault.connect(b).buyMin(first, { value: TICKET }))
      .to.be.revertedWithCustomError(vault, "Slippage");
    // 设一个拿得到的下限就该成功
    const quote = await vault.quoteBuy(TICKET - (TICKET * BURN_BPS) / 10000n);
    await vault.connect(b).buyMin(quote, { value: TICKET });
    expect((await vault.positions(1)).tokens).to.equal(quote);
    // minTokensOut = 0 等于不设限，跟 buy() 一模一样
    const [, , c] = await ethers.getSigners();
    await vault.connect(c).buyMin(0, { value: TICKET });
    expect(Number((await vault.stats()).totalPositions)).to.equal(3);
    await mustBeSolvent(vault);
  });

  it("🔴 挤兑实测：所有人同时夺门而出，最后一个能拿回多少（白皮书要写这个真数）", async function () {
    this.timeout(300000);
    const { vault } = await deploy();
    const N = 50;
    const ws = await wallets(N);
    for (const w of ws) await vault.connect(w).buy({ value: TICKET });

    // 还在场的人，按队列顺序（持仓多的先跑）全部 exit
    const live = [];
    for (let i = 0; i < N; i++) {
      const p = await vault.positions(i);
      if (Number(p.status) === 1) live.push({ i, w: ws[i] });
    }
    let worst = null, worstAt = -1;
    for (const { i, w } of live) {
      const before = await ethers.provider.getBalance(w.address);
      const rc = await (await vault.connect(w).exit()).wait();
      const after = await ethers.provider.getBalance(w.address);
      const got = after - before + rc.gasUsed * rc.gasPrice;      // 扣掉 gas 才是真拿回的
      if (worst === null || got < worst) { worst = got; worstAt = i; }
    }
    const mult = Number((worst * 10000n) / TICKET) / 1e4;
    console.log(`      ${N} 人全部夺门而出：最后出场的 #${worstAt} 只拿回 ${ethers.formatEther(worst)} ETH = ${mult.toFixed(4)}× 票价`);
    expect(worst).to.be.gte(0n);
    await mustBeSolvent(vault);
    // Optional: set EVIDENCE_DIR to save the stampede result to a file.
    if (process.env.EVIDENCE_DIR) require("fs").writeFileSync(
      require("path").join(process.env.EVIDENCE_DIR, "v3_bankrun.txt"),
      `${N} buyers, everyone exits in queue order\nworst position #${worstAt} recovered ${ethers.formatEther(worst)} ETH = ${mult.toFixed(4)}x of the 0.01 ticket\n`);
  });
});

/* ═══════════ 2026-09-22 上线前审计补的：把「一钱包一票」到底是什么意思钉死 ═══════════
   审计时读源码发现 positionOf 在 _close() 里【没有】被清掉 —— 也就是说这条限制
   不是「同时只能有一张票」，而是【这个钱包这辈子只能买一张】：
   十倍出场拿完钱，或者自己 exit 走人，这个地址就再也进不来了。
   这跟站上写的 "One ticket per wallet"、"A second ticket from the same wallet reverts"
   字面不冲突，但绝大多数人会理解成「持有期间一张」。所以先用测试把真实行为钉死，
   再决定是改合约还是改文案 —— 不许让它含糊着上主网。 */
describe("SpiralVault v3 · 一钱包一票到底管多久（上线前审计）", function () {
  it("🔴 出场之后【永远】不能再买：positionOf 从不清零", async () => {
    const { vault } = await deploy();                 // LOCK = 0，可以立刻退出
    const [a] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    expect((await vault.infoOf(a.address)).exists).to.equal(true);

    await vault.connect(a).exit();                    // 自己走人，仓位关闭
    expect(Number((await vault.positions(0)).status)).to.equal(3);   // Exited

    // 仓位已经不在场了，但这个地址依然买不进来
    expect(await vault.liveCount()).to.equal(0n);
    await expect(vault.connect(a).buy({ value: TICKET }))
      .to.be.revertedWithCustomError(vault, "OneTicketPerWallet");
    await mustBeSolvent(vault);
  });

  it("🔴 十倍拿完钱之后同样再也进不来", async () => {
    const { vault } = await deploy();
    const [first] = await ethers.getSigners();
    await vault.connect(first).buy({ value: TICKET });             // 第 0 张，份额最大
    const ws = await wallets(40, "0.05");
    for (const w of ws) {
      await vault.connect(w).buy({ value: TICKET });
      if (Number((await vault.positions(0)).status) === 2) break;  // AutoSold
    }
    expect(Number((await vault.positions(0)).status),
      "40 张票还没把第 0 张顶到 10×，用例前提不成立").to.equal(2);

    await expect(vault.connect(first).buy({ value: TICKET }))
      .to.be.revertedWithCustomError(vault, "OneTicketPerWallet");
    await mustBeSolvent(vault);
  });
});
