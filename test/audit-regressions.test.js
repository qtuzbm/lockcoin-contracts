// Independent regression audit. Runs exclusively on the in-process Hardhat chain.
// No real keys, public RPC transactions, or production accounts are used here.
const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const TICKET = ethers.parseEther("0.01");
const DEAD = "0x000000000000000000000000000000000000dEaD";

async function deploy(overrides = {}) {
  const pons = overrides.plain ? null : await (await ethers.getContractFactory("MockPonsCurve")).deploy();
  const V = await ethers.getContractFactory("SpiralVault");
  const args = ["Audit Share", "AUD", TICKET, 10n, TICKET * 2n,
    ethers.parseEther("1000000"), 0n, 10n,
    pons ? await pons.getAddress() : ethers.ZeroAddress, pons ? 1500n : 0n];
  for (const [key, value] of Object.entries(overrides.args || {})) args[Number(key)] = value;
  const vault = await V.deploy(...args);
  await vault.waitForDeployment();
  return { vault, pons };
}

async function buyers(count, offset = 1) {
  const result = [];
  for (let i = 0; i < count; i++) {
    const addr = ethers.getAddress(ethers.toBeHex(BigInt(1_000_000 + offset + i), 20));
    await network.provider.send("hardhat_setBalance", [addr, ethers.toBeHex(ethers.parseEther("1"))]);
    await network.provider.send("hardhat_impersonateAccount", [addr]);
    result.push(await ethers.getSigner(addr));
  }
  return result;
}

async function liabilitiesMatchCash(vault, pendingOwners = []) {
  let liability = 0n;
  for (const who of pendingOwners) liability += await vault.pending(who);
  expect(await vault.totalPending()).to.equal(liability);
  const [ok, paidIn, paidOut, pool, burned] = await vault.solvent();
  expect(ok).to.equal(true);
  expect(paidIn).to.equal(paidOut + pool + burned);
  expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(pool + liability);
}

async function assertHeap(vault) {
  const all = await vault.positionsPage(0, await vault.positionsLength());
  const expected = all.map((p, idx) => ({ p, idx: BigInt(idx) }))
    .filter(x => x.p.status === 1n)
    .sort((a, b) => a.p.tokens === b.p.tokens ? Number(a.idx - b.idx) : a.p.tokens > b.p.tokens ? -1 : 1);
  const rows = await vault.queueTop(expected.length + 2);
  expect(rows.map(x => x.idx)).to.deep.equal(expected.map(x => x.idx));
  expect(await vault.liveCount()).to.equal(BigInt(expected.length));
  expect(await vault.heapLength()).to.equal(BigInt(expected.length));
  for (let i = 0; i < expected.length; i++) {
    expect(await vault.rankOf(expected[i].p.owner, 1000)).to.equal(BigInt(i + 1));
  }
}

describe("Independent audit regressions", function () {
  this.timeout(180000);
  before(async () => {
    if (network.name !== "hardhat" || (await ethers.provider.getNetwork()).chainId !== 31337n) {
      throw new Error("Audit tests are local-only: refusing a non-Hardhat network");
    }
  });

  it("quotes and closes safely when the intermediate reserve product exceeds uint256", async () => {
    const vn = 2n ** 127n, vt = 2n ** 223n;
    const { vault } = await deploy({ plain: true, args: { 4: vn, 5: vt } });
    const expected = vt - (vn * vt + vn + TICKET - 1n) / (vn + TICKET);
    expect(await vault.quoteBuy(TICKET)).to.equal(expected);
    const [a] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    expect((await vault.infoOf(a.address)).tokens).to.equal(expected);
    await vault.connect(a).exit();
    await liabilitiesMatchCash(vault);
  });

  it("rejects a payout multiplier that makes every first buy overflow", async () => {
    const V = await ethers.getContractFactory("SpiralVault");
    await expect(V.deploy("A", "A", TICKET, ethers.MaxUint256, TICKET * 2n,
      ethers.parseEther("1000000"), 0, 10, ethers.ZeroAddress, 0))
      .to.be.revertedWithCustomError(V, "BadParams");
  });

  it("rejects a lock duration that cannot fit the position's uint64 timestamp", async () => {
    const V = await ethers.getContractFactory("SpiralVault");
    await expect(V.deploy("A", "A", TICKET, 10, TICKET * 2n,
      ethers.parseEther("1000000"), ethers.MaxUint256, 10, ethers.ZeroAddress, 0))
      .to.be.revertedWithCustomError(V, "BadParams");
  });

  it("keeps infoOf affordable at 260 live positions, including a late position", async () => {
    const { vault } = await deploy({ plain: true, args: { 3: 1000n } });
    const ws = await buyers(260);
    for (const w of ws) await vault.connect(w).buy({ value: TICKET });
    expect(await vault.liveCount()).to.equal(260n);
    const gas = await vault.infoOf.estimateGas(ws[259].address);
    console.log(`      infoOf(260 live, late position) gas=${gas}`);
    // Position visibility must not require scanning the complete heap. An unknown
    // rank is acceptable; the principal, status and current value must remain readable.
    expect(gas).to.be.lessThan(500000n);
    const info = await vault.infoOf(ws[259].address, { gasLimit: 500000 });
    expect(info.exists).to.equal(true);
    expect(info.paid).to.equal(TICKET);
    expect(info.currentValue).to.be.greaterThan(0n);
    await liabilitiesMatchCash(vault);
  });

  it("rolls back Pons balances, burn counters and referrals if share slippage fails", async () => {
    const { vault, pons } = await deploy();
    const [a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });
    const t = await ethers.getContractAt("MockPonsToken", await pons.token());
    const deadBefore = await t.balanceOf(DEAD);
    const ponsCashBefore = await ethers.provider.getBalance(await pons.getAddress());
    const burnedBefore = await vault.totalBurnedNative();
    const ref = ethers.encodeBytes32String("audit");
    await expect(vault.connect(b).buyWithRefMin(ref, ethers.MaxUint256, { value: TICKET }))
      .to.be.revertedWithCustomError(vault, "Slippage");
    expect(await t.balanceOf(DEAD)).to.equal(deadBefore);
    expect(await ethers.provider.getBalance(await pons.getAddress())).to.equal(ponsCashBefore);
    expect(await vault.totalBurnedNative()).to.equal(burnedBefore);
    expect(await vault.positionsLength()).to.equal(1n);
    expect(await vault.positionOf(b.address)).to.equal(0n);
    await liabilitiesMatchCash(vault);
  });

  it("protects a seller's minimum output when a preceding exit changes the quote", async () => {
    const { vault } = await deploy();
    const [a, b, c] = await ethers.getSigners();
    for (const w of [a, b, c]) await vault.connect(w).buy({ value: TICKET });
    const quoteBefore = await vault.quoteSell((await vault.infoOf(b.address)).tokens);
    await vault.connect(a).exit();
    const quoteAfter = await vault.quoteSell((await vault.infoOf(b.address)).tokens);
    expect(quoteAfter).to.be.lessThan(quoteBefore);
    const hasExitMin = vault.interface.fragments.some(f => f.type === "function" && f.name === "exitMin");
    expect(hasExitMin, "exit has no minimum-native-output protection").to.equal(true);
    await expect(vault.connect(b).exitMin(quoteBefore)).to.be.reverted;
    expect((await vault.infoOf(b.address)).status).to.equal(1n);
    await vault.connect(b).exitMin(quoteAfter);
    expect((await vault.infoOf(b.address)).status).to.equal(3n);
    await liabilitiesMatchCash(vault);
  });

  it("preserves every pending liability while later buyers and exits use the pool", async () => {
    const { vault } = await deploy();
    const R = await ethers.getContractFactory("RejectingBuyer");
    const r1 = await R.deploy();
    const r2 = await R.deploy();
    const address = await vault.getAddress();
    const owners = [await r1.getAddress(), await r2.getAddress()];
    await r1.doBuy(address, { value: TICKET });
    await r2.doBuy(address, { value: TICKET });
    const ws = await buyers(55, 500);
    for (const w of ws) await vault.connect(w).buy({ value: TICKET });
    expect(await vault.pending(owners[0])).to.be.greaterThanOrEqual(TICKET * 10n);
    expect(await vault.pending(owners[1])).to.be.greaterThanOrEqual(TICKET * 10n);
    await liabilitiesMatchCash(vault, owners);
    // A negative control proves solvent checks unpaid liabilities, not just pool cash.
    // This synthetic balance mutation exists only inside the local test snapshot.
    const snapshot = await network.provider.send("evm_snapshot");
    await network.provider.send("hardhat_setBalance", [address, ethers.toBeHex(await vault.realNative())]);
    expect((await vault.solvent())[0]).to.equal(false);
    await network.provider.send("evm_revert", [snapshot]);
    for (let i = 54; i >= 44; i--) {
      if ((await vault.infoOf(ws[i].address)).status === 1n) await vault.connect(ws[i]).exit();
    }
    await liabilitiesMatchCash(vault, owners);
    await r1.setAccept(true);
    await r1.doClaim(address);
    await liabilitiesMatchCash(vault, owners);
    await expect(r2.doClaim(address)).to.be.reverted;
    await liabilitiesMatchCash(vault, owners);
    await r2.setAccept(true);
    await r2.doClaim(address);
    await liabilitiesMatchCash(vault, owners);
  });

  it("keeps heap order after interleaved buys, exits, burn failure and graduation", async () => {
    const { vault, pons } = await deploy();
    const ws = await buyers(58, 700);
    for (let i = 0; i < 25; i++) await vault.connect(ws[i]).buy({ value: TICKET });
    await assertHeap(vault);
    for (let i = 4; i < 22; i += 3) {
      if ((await vault.infoOf(ws[i].address)).status === 1n) await vault.connect(ws[i]).exit();
    }
    await pons.setFailNextBuy(true);
    for (let i = 25; i < 35; i++) await vault.connect(ws[i]).buy({ value: TICKET });
    await assertHeap(vault);
    await pons.setFailNextBuy(false);
    for (let i = 35; i < 44; i++) await vault.connect(ws[i]).buy({ value: TICKET });
    await pons.forceGraduate();
    const burned = await vault.totalBurnedTokens();
    for (let i = 44; i < 58; i++) await vault.connect(ws[i]).buy({ value: TICKET });
    expect(await vault.totalBurnedTokens()).to.equal(burned);
    expect((await vault.spiral()).ponsGraduated).to.equal(true);
    await assertHeap(vault);
    await liabilitiesMatchCash(vault);
  });

  it("rejects reentrant exit during payout without losing the recipient's money", async () => {
    const solc = require("solc");
    const source = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface I { function buy() external payable; function exit() external; }
contract AuditReceiver {
  address public vault; bool public blocked;
  function buy(address v) external payable { vault=v; I(v).buy{value:msg.value}(); }
  function exit() external { I(vault).exit(); }
  receive() external payable {
    (bool ok,) = vault.call(abi.encodeWithSignature("exit()"));
    require(!ok,"reentered"); blocked=true;
  }
}`;
    const output = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity",
      sources: { "AuditReceiver.sol": { content: source } },
      settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } }
    })));
    const fatal = (output.errors || []).filter(x => x.severity === "error");
    expect(fatal.map(x => x.formattedMessage)).to.deep.equal([]);
    const artifact = output.contracts["AuditReceiver.sol"].AuditReceiver;
    const [signer] = await ethers.getSigners();
    const receiver = await new ethers.ContractFactory(artifact.abi, artifact.evm.bytecode.object, signer).deploy();
    const { vault } = await deploy();
    const address = await receiver.getAddress();
    await receiver.buy(await vault.getAddress(), { value: TICKET });
    const quote = await vault.quoteSell((await vault.infoOf(address)).tokens);
    await receiver.exit();
    expect(await receiver.blocked()).to.equal(true);
    expect(await ethers.provider.getBalance(address)).to.equal(quote);
    expect(await vault.pending(address)).to.equal(0n);
    await liabilitiesMatchCash(vault, [address]);
  });
});
