// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LockCoin} from "./LockCoin.sol";

/// @notice Pons V2 曲线：金库只用到 buy()。签名取自链上已验证源码
///         PonsV2BondingCurve.sol（Robinhood 4663，工厂 0x7eD598Bc…）。
interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external payable returns (uint256 tokensOut);
    function token() external view returns (address);
    function graduated() external view returns (bool);
    function readyToGraduate() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
}

/// @title SpiralVault — 一票 0.01 · 买入即锁 · 到 0.1 自动卖 · 每票都在 Pons 上真实回购并销毁
///
/// @notice 一台机器，两个引擎，都在链上，都可核验：
///
///  【引擎一 · 十倍机】票价固定，一个钱包一张。金库自营常积曲线（x·y=k，带虚拟储备）为份额定价。
///    份额凭证是不可转让的 ERC20（看得见、转不动），只有金库能铸和销。
///    每来一张新票就检查「持仓最多的那个人」：他的份额按曲线能换回 ≥ targetMult 倍**票面全款**时，
///    金库当场把他的份额销毁、按曲线卖回、原生币直接打进他钱包。任何人都能调 settle() 兜底。
///    lockPeriod=0 时随时可按曲线价 exit()（可能亏），所以它不是蜜罐。
///
///  【引擎二 · 单向销毁】每张票里固定 burnBps 的比例**不进金库池**，而是当场在 Pons 曲线上
///    买入该项目在 Pons 发行的真代币，并把买到的币直接送进 0x…dEaD。
///    这一步是原子的、单向的、不可逆的：金库没有任何函数能把销毁的币取回来，
///    因为它们从来没有进过金库的地址。销毁量随票数单调递增 —— 这就是「螺旋」里唯一
///    真正只增不减的那一项，其余部分（价格、人数）都可能回落。
///
/// @dev 螺旋的诚实边界，写在合约注释里而不是只写在官网上：
///   · 销毁只减少流通供应，**不承诺价格上涨** —— 外部持有人随时可以在 Pons 上砸盘。
///   · 十倍的钱来自后来买票的人。进 = 出 + 池中余额，恒等式在 totalIn/totalOut/realNative 上可核。
///     因此**最多只有约 1/targetMult 的票能十倍出场**，这是算术上界不是目标。
///   · 拿去销毁的那部分（burnBps）不参与十倍兑付，它是所有持币人的公共品，
///     代价是十倍出场率比不销毁时略低。实测 15% 销毁时出场率 9.1% → 7.7%。
///
/// @dev 无 owner、无税、无暂停、无升级、无提款后门。原生币离开合约只有四条路：
///      十倍强卖 / 到期退出 / 领取 pending / 每票固定比例的 Pons 回购销毁。
///      全部参数在构造时写死成 immutable，部署后任何人都改不了，包括部署者。
///
/// @dev 血统（这一份是四个会话成果的合并，不是重写）：
///   · 数组二叉最大堆队列（O(log n)）—— 会话 ca2c29b2。原链表版 buy() gas 随人数线性涨，
///     实测 260 人/19 退出后 390,969 → 1,254,227（3.2x），上千人撞区块上限卡死金库。
///   · buyWithRef / Referred 渠道码链上归因 + positionsPage —— 会话 6c4aa8d0（并 matrix 发布器）。
///   · 曲线取整一律对池子有利、_pay 的 30k gas 护栏、lockPeriod=0 —— 本线 v2。
///   · Pons 回购销毁引擎、票款拆分 —— 本次 v3。
contract SpiralVault is ReentrancyGuard {

    // v3.2 is a new deployment; immutable older deployments cannot be upgraded.
    string public constant VERSION = "3.2.0";
    uint256 public constant NONE = type(uint256).max;
    uint256 public constant INFO_RANK_SCAN_LIMIT = 128;
    uint256 private constant IDX_MASK = 0xffffffff; // 堆键低 32 位放 ~idx

    LockCoin public immutable token;
    uint256 public immutable ticket;          // 每张票固定金额 (wei)
    uint256 public immutable targetMult;      // 目标倍数，如 10
    uint256 public immutable lockPeriod;      // 锁仓期(秒)，到期可按曲线价退出；0 = 随时可退出
    uint256 public immutable virtualNative;   // 曲线虚拟原生币储备
    uint256 public immutable virtualToken;    // 曲线虚拟代币储备
    uint256 public immutable maxSettlePerBuy; // 每次买入最多顺带结算几人（防 gas 爆）

    // ── 引擎二：Pons 回购销毁 ──
    /// @notice Pons V2 曲线地址。零地址 = 本金库不接 Pons（纯十倍机，burnBps 必须为 0）。
    IPonsCurve public immutable ponsCurve;
    /// @notice 在 Pons 上发行的真代币地址（可自由交易，与本合约的不可转让份额是两个东西）
    address public immutable ponsToken;
    /// @notice 每张票里拿去回购销毁的比例（基点）。部署后不可改。
    uint256 public immutable burnBps;
    /// @notice 销毁去向：直接把买到的币打进这里，金库地址上从不经手。
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant BPS = 10_000;
    /// @dev 单笔回购给 Pons 曲线的 gas 上限。给够（Pons buy 实测约 20 万），
    ///      但必须有上限：Pons 侧任何异常都不能让买票这条主路 revert。
    uint256 private constant BURN_GAS = 400_000;

    uint256 public totalBurnedNative; // 累计投进回购的原生币
    uint256 public totalBurnedTokens; // 累计销毁的 Pons 代币（买到即送进 BURN_SINK）
    uint256 public burnCount;         // 成功回购次数
    uint256 public burnSkipCount;     // 回购失败次数（钱回落进金库池，不丢）

    uint256 public reserveNative; // 虚拟 + 真实
    uint256 public reserveToken;  // 虚拟 + 未售出
    uint256 public realNative;    // 真实持有的原生币

    enum Status { None, Live, AutoSold, Exited }
    struct Position {
        address owner;
        uint256 tokens;
        uint256 paid;
        uint256 received;
        uint64 boughtAt;
        uint64 closedAt;
        Status status;
    }
    Position[] public positions;

    /// @dev 最大堆：heap[0] 是「持仓最多、并列时最早买入」的那个仓位。
    ///      堆键 = tokens << 32 | (uint32.max - idx)，直接比大小即可（并列时 idx 小的键更大 = 优先）。
    ///      键里带着 tokens，比较不用再回读 positions[]，每层少一次 SLOAD。
    uint256[] private heap;
    mapping(uint256 => uint256) private heapSlot; // 仓位 idx => 堆下标+1；0 = 不在堆里

    uint256 public liveCount;
    mapping(address => uint256) public positionOf; // idx+1；0 = 没买过
    mapping(address => uint256) public pending;    // 打款失败时暂存，可 claim
    uint256 public totalPending;                  // 尚未实际打出的负债，不属于可交易池

    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public autoSoldCount;
    uint256 public exitedCount;

    event VaultCreated(
        address indexed token, string name, string symbol,
        uint256 ticket, uint256 targetMult, uint256 lockPeriod,
        uint256 virtualNative, uint256 virtualToken, uint256 maxSettlePerBuy
    );
    event SpiralConfigured(address indexed ponsCurve, address indexed ponsToken, uint256 burnBps, address burnSink);
    event Bought(uint256 indexed idx, address indexed buyer, uint256 paid, uint256 tokens);
    event Referred(uint256 indexed idx, bytes32 indexed ref, address indexed buyer);
    event AutoSold(uint256 indexed idx, address indexed owner, uint256 tokens, uint256 received, uint256 multX1e4);
    event Exited(uint256 indexed idx, address indexed owner, uint256 tokens, uint256 received, uint256 multX1e4);
    event PendingCredited(address indexed owner, uint256 amount);
    event Claimed(address indexed owner, uint256 amount);
    /// @notice 一次成功的回购销毁。tokensBurned 是直接进 0x…dEaD 的数量，链上可独立核验。
    event Burned(uint256 indexed idx, uint256 nativeSpent, uint256 tokensBurned);
    /// @notice 回购这一步失败（Pons 毕业/暂停/异常），这笔钱已回落进金库池，没有丢。
    event BurnSkipped(uint256 indexed idx, uint256 nativeKept, bytes reason);

    error WrongTicket(uint256 expected, uint256 got);
    error OneTicketPerWallet();
    error NoPosition();
    error NotLive();
    error StillLocked(uint256 unlockAt);
    error NothingPending();
    error DirectTransferRejected();
    error BadParams();
    error Slippage(uint256 wanted, uint256 got);
    error ExitSlippage(uint256 wanted, uint256 got);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 ticket_,
        uint256 targetMult_,
        uint256 virtualNative_,
        uint256 virtualToken_,
        uint256 lockPeriod_,
        uint256 maxSettlePerBuy_,
        address ponsCurve_,
        uint256 burnBps_
    ) {
        // lockPeriod_ 可为 0 = 随时可按曲线价退出
        if (
            ticket_ == 0 || ticket_ > type(uint128).max || targetMult_ < 2 ||
            targetMult_ > type(uint256).max / ticket_ || virtualNative_ == 0 ||
            // Even bounded reserves can have a product exceeding uint256.
            // All curve products use full-precision mulDiv below.
            virtualNative_ > type(uint128).max ||
            virtualToken_ == 0 || virtualToken_ > type(uint224).max || maxSettlePerBuy_ == 0 ||
            block.timestamp > type(uint64).max || lockPeriod_ > type(uint64).max - block.timestamp
        ) revert BadParams();
        // 销毁比例硬上限 30%：再高，十倍兑付就被抽空到不诚实的程度。
        if (burnBps_ > 3_000) revert BadParams();
        // 不接 Pons 就不许设销毁比例；接了 Pons 就必须能读出它的代币地址。
        if (ponsCurve_ == address(0) && burnBps_ != 0) revert BadParams();
        if (ponsCurve_ != address(0)) {
            ponsToken = IPonsCurve(ponsCurve_).token();
            if (ponsToken == address(0)) revert BadParams();
        }
        ponsCurve = IPonsCurve(ponsCurve_);
        burnBps = burnBps_;
        token = new LockCoin(name_, symbol_, address(this));
        ticket = ticket_;
        targetMult = targetMult_;
        lockPeriod = lockPeriod_;
        virtualNative = virtualNative_;
        virtualToken = virtualToken_;
        maxSettlePerBuy = maxSettlePerBuy_;
        reserveNative = virtualNative_;
        reserveToken = virtualToken_;
        emit VaultCreated(address(token), name_, symbol_, ticket_, targetMult_, lockPeriod_, virtualNative_, virtualToken_, maxSettlePerBuy_);
        emit SpiralConfigured(ponsCurve_, ponsToken, burnBps_, BURN_SINK);
    }

    // ─────────────── 曲线 ───────────────
    // 取整方向：两边都让**池子**占那 1 wei，杜绝「买入后立刻退出反而多拿」。

    /// @notice 投入 nativeIn 能按曲线拿到多少币（向下取整）
    function quoteBuy(uint256 nativeIn) public view returns (uint256) {
        return reserveToken - Math.mulDiv(reserveNative, reserveToken, reserveNative + nativeIn, Math.Rounding.Ceil);
    }

    /// @notice 卖回 tokens 能按曲线拿回多少原生币（向下取整，且不超过真实储备）
    function quoteSell(uint256 tokens) public view returns (uint256) {
        uint256 out = reserveNative - Math.mulDiv(reserveNative, reserveToken, reserveToken + tokens, Math.Rounding.Ceil);
        return out > realNative ? realNative : out;
    }

    /// @notice 当前边际价：1 个币(1e18)值多少 wei
    function curvePrice() external view returns (uint256) {
        return Math.mulDiv(reserveNative, 1e18, reserveToken);
    }

    // ─────────────── 买入 ───────────────

    function buy() external payable nonReentrant { _buy(bytes32(0), 0); }

    /// @notice 带渠道码的买入。ref 只进 Referred 事件，不影响金额、队列、结算。
    function buyWithRef(bytes32 ref) external payable nonReentrant { _buy(ref, 0); }

    /// @notice 兼容旧签名：hint 在堆结构下没有意义，直接忽略；行为与 buyWithRef 完全一致。
    function buyWithHint(uint256, bytes32 ref) external payable nonReentrant { _buy(ref, 0); }

    /// @notice 带滑点下限的买入 —— 拿不到 minTokensOut 份就整笔回滚。
    /// @dev 🔴 2026-09-21 补（Gemini 对抗审计第二轮指出，我自己漏了）：
    ///      票价是定死的 0.01，但**同一笔钱能买到多少份**取决于下单那一刻的曲线状态。
    ///      同一个区块里别人先成交，你就拿到更少的份、排到更后面，而界面上报的是你点击时的数。
    ///      这不是有人能直接偷走你的钱，但「看到的份额 ≠ 拿到的份额」本身就不老实。
    ///      合约不可升级，这种参数只能在部署前加，上线后补不上，所以现在加。
    ///      老签名 buy() / buyWithRef() 全部保留，传 0 即不设下限，行为与以前完全一致。
    function buyMin(uint256 minTokensOut) external payable nonReentrant { _buy(bytes32(0), minTokensOut); }

    /// @notice 带渠道码 + 滑点下限的买入。
    function buyWithRefMin(bytes32 ref, uint256 minTokensOut) external payable nonReentrant { _buy(ref, minTokensOut); }

    /// @dev 一张票走两条路：burnBps 去 Pons 回购销毁，其余进金库曲线池。
    ///      注意定价基数是**进池的那部分**，而目标仍是 paid（票面全款）的 targetMult 倍 ——
    ///      销毁的代价老老实实体现在「要多等几张票」上，不靠会计把它藏起来。
    function _buy(bytes32 ref, uint256 minTokensOut) internal {
        if (msg.value != ticket) revert WrongTicket(ticket, msg.value);
        if (positionOf[msg.sender] != 0) revert OneTicketPerWallet();

        uint256 idx = positions.length;
        if (idx >= IDX_MASK) revert BadParams(); // 堆键留了 32 位给 idx

        // ① 先做回购销毁（interaction 在前，但它对本合约状态无依赖，
        //    且被 nonReentrant + 定额 gas + try/catch 三重围住；失败即回落进池）
        uint256 toBurn = (msg.value * burnBps) / BPS;
        uint256 burned = toBurn == 0 ? 0 : _burnBuy(idx, toBurn);
        uint256 toPool = msg.value - burned;

        // ② 进金库曲线池
        uint256 out = quoteBuy(toPool);
        if (out == 0) revert BadParams(); // 曲线已被榨干（理论上不可达，兜底）
        if (out < minTokensOut) revert Slippage(minTokensOut, out);
        reserveNative += toPool;
        reserveToken -= out;
        realNative += toPool;
        totalIn += msg.value; // 记全款：进 = 出 + 池 + 已销毁，三者可对账

        positions.push(Position({
            owner: msg.sender, tokens: out, paid: msg.value, received: 0,
            boughtAt: uint64(block.timestamp), closedAt: 0, status: Status.Live
        }));
        positionOf[msg.sender] = idx + 1;
        liveCount++;
        _heapPush(idx, out);
        token.mint(msg.sender, out);
        emit Bought(idx, msg.sender, msg.value, out);
        if (ref != bytes32(0)) emit Referred(idx, ref, msg.sender);

        _settle(maxSettlePerBuy);
    }

    /// @dev 在 Pons 曲线上买币并直接送进 0x…dEaD。返回实际花掉的原生币。
    ///      失败返回 0（这笔钱回落进金库池，对买票人只会更有利，不会丢）。
    ///      🔴 recipient 直接写 BURN_SINK：币从不进本合约地址，所以合约里
    ///      不存在任何能把它取回来的代码路径 —— 这比「先收进来再转走」强得多。
    function _burnBuy(uint256 idx, uint256 amount) private returns (uint256) {
        try ponsCurve.buy{value: amount, gas: BURN_GAS}(amount, 0, BURN_SINK) returns (uint256 tokensOut) {
            totalBurnedNative += amount;
            totalBurnedTokens += tokensOut;
            burnCount++;
            emit Burned(idx, amount, tokensOut);
            return amount;
        } catch (bytes memory reason) {
            // Pons 毕业 / 曲线异常 / gas 不够都会走到这。钱还在本合约里，继续进池。
            burnSkipCount++;
            emit BurnSkipped(idx, amount, reason);
            return 0;
        }
    }

    receive() external payable { revert DirectTransferRejected(); }

    // ─────────────── 结算 ───────────────

    /// @notice 任何人可调：从持仓最大者开始，把达标者逐个强卖，最多 max 人
    function settle(uint256 max) external nonReentrant returns (uint256 n) {
        return _settle(max);
    }

    function _settle(uint256 max) internal returns (uint256 n) {
        while (heap.length != 0 && n < max) {
            uint256 idx = _keyIdx(heap[0]);
            Position storage p = positions[idx];
            uint256 out = quoteSell(p.tokens);
            if (out < p.paid * targetMult) break;
            _close(idx, out, Status.AutoSold);
            unchecked { n++; }
        }
    }

    /// @notice 锁仓期到了还没达标：本人可按当前曲线价退出
    function exit() external nonReentrant {
        _exit(0);
    }

    /// @notice Exit only when the current curve payout meets the chosen minimum.
    ///         Legacy exit() remains available and applies no slippage minimum.
    function exitMin(uint256 minNativeOut) external nonReentrant {
        _exit(minNativeOut);
    }

    function _exit(uint256 minNativeOut) internal {
        uint256 slot = positionOf[msg.sender];
        if (slot == 0) revert NoPosition();
        uint256 idx = slot - 1;
        Position storage p = positions[idx];
        if (p.status != Status.Live) revert NotLive();
        uint256 unlockAt = uint256(p.boughtAt) + lockPeriod;
        if (block.timestamp < unlockAt) revert StillLocked(unlockAt);
        uint256 out = quoteSell(p.tokens);
        if (out < minNativeOut) revert ExitSlippage(minNativeOut, out);
        _close(idx, out, Status.Exited);
    }

    function claim() external nonReentrant {
        uint256 amt = pending[msg.sender];
        if (amt == 0) revert NothingPending();
        pending[msg.sender] = 0;
        totalPending -= amt;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "claim failed");
        emit Claimed(msg.sender, amt);
    }

    function _close(uint256 idx, uint256 out, Status st) internal {
        Position storage p = positions[idx];
        uint256 tokens = p.tokens;
        // effects
        reserveToken += tokens;
        reserveNative -= out;
        realNative -= out;
        totalOut += out;
        p.status = st;
        p.received = out;
        p.closedAt = uint64(block.timestamp);
        liveCount--;
        if (st == Status.AutoSold) autoSoldCount++; else exitedCount++;
        _heapRemove(idx);
        token.burn(p.owner, tokens);
        uint256 multX1e4 = (out * 1e4) / p.paid;
        if (st == Status.AutoSold) emit AutoSold(idx, p.owner, tokens, out, multX1e4);
        else emit Exited(idx, p.owner, tokens, out, multX1e4);
        // interaction
        _pay(p.owner, out);
    }

    /// @dev 30_000 gas 上限是护栏不是抠门：恶意合约买家只能烧掉这点 gas，
    ///      烧完 call 返回 false → 记 pending，队列继续推进，别人的 buy() 不会被他卡死。
    function _pay(address to, uint256 amt) internal {
        if (amt == 0) return;
        (bool ok, ) = to.call{value: amt, gas: 30_000}("");
        if (!ok) {
            pending[to] += amt;
            totalPending += amt;
            emit PendingCredited(to, amt);
        }
    }

    // ─────────────── 队列：数组二叉最大堆 ───────────────
    // 键 = tokens << 32 | (uint32.max - idx)。tokens 大者优先；并列时 idx 小（先买）者优先。

    function _key(uint256 idx, uint256 tokens) private pure returns (uint256) {
        return (tokens << 32) | (IDX_MASK - idx);
    }
    function _keyIdx(uint256 key) private pure returns (uint256) {
        return IDX_MASK - (key & IDX_MASK);
    }

    function _heapPush(uint256 idx, uint256 tokens) private {
        uint256 slot = heap.length;
        heap.push(0); // 占位，实际值由 _siftUp 写入
        _siftUp(slot, _key(idx, tokens));
    }

    function _heapRemove(uint256 idx) private {
        uint256 s = heapSlot[idx];
        if (s == 0) return;
        uint256 slot = s - 1;
        delete heapSlot[idx];
        uint256 last = heap.length - 1;
        uint256 movedKey = heap[last];
        heap.pop();
        if (slot == last) return;      // 删的就是最后一个
        _siftDown(slot, movedKey);     // 先下沉；沉不动再上浮（从中间删时两种都可能）
        uint256 landed = heapSlot[_keyIdx(movedKey)] - 1;
        if (landed == slot) _siftUp(slot, movedKey);
    }

    function _siftUp(uint256 slot, uint256 key) private {
        while (slot != 0) {
            uint256 parent = (slot - 1) >> 1;
            uint256 pk = heap[parent];
            if (key <= pk) break;
            heap[slot] = pk;
            heapSlot[_keyIdx(pk)] = slot + 1;
            slot = parent;
        }
        heap[slot] = key;
        heapSlot[_keyIdx(key)] = slot + 1;
    }

    function _siftDown(uint256 slot, uint256 key) private {
        uint256 n = heap.length;
        while (true) {
            uint256 l = (slot << 1) + 1;
            if (l >= n) break;
            uint256 best = l;
            uint256 bestKey = heap[l];
            uint256 r = l + 1;
            if (r < n) {
                uint256 rk = heap[r];
                if (rk > bestKey) { best = r; bestKey = rk; }
            }
            if (bestKey <= key) break;
            heap[slot] = bestKey;
            heapSlot[_keyIdx(bestKey)] = slot + 1;
            slot = best;
        }
        heap[slot] = key;
        heapSlot[_keyIdx(key)] = slot + 1;
    }

    // ─────────────── 只读 ───────────────

    function positionsLength() external view returns (uint256) { return positions.length; }

    /// @notice 按下标分页取仓位（给监控/归因用），一次 eth_call 拿完
    function positionsPage(uint256 from, uint256 n) external view returns (Position[] memory out) {
        uint256 len = positions.length;
        if (from >= len) return new Position[](0);
        uint256 end = from + n; if (end > len) end = len;
        out = new Position[](end - from);
        for (uint256 i = from; i < end; i++) out[i - from] = positions[i];
    }

    /// @notice 兼容旧接口。堆插入是 O(log n) 且不需要外部提示，恒返回 NONE。
    function hintFor(uint256) external pure returns (uint256) { return NONE; }
    function heapLength() external view returns (uint256) { return heap.length; }
    /// @notice 下一个出场的人（持仓最大者）的仓位号；没人时 = NONE
    function head() public view returns (uint256) { return heap.length == 0 ? NONE : _keyIdx(heap[0]); }

    struct QueueRow {
        uint256 idx; address owner; uint256 tokens; uint256 paid;
        uint256 value; uint256 multX1e4; uint64 boughtAt;
    }

    /// @notice 队列前 k 名（持仓大者在前），一次 RPC 取完。
    /// @dev 堆的 top-k：候选集里每次挑最大的取出，再把它的两个孩子放进候选集。
    ///      候选集线性挑选，最坏 O(k^2) 次比较；调用方应限制 k。
    function queueTop(uint256 k) external view returns (QueueRow[] memory rows) {
        uint256 n = heap.length;
        if (k > n) k = n;
        rows = new QueueRow[](k);
        if (k == 0) return rows;
        uint256[] memory cand = new uint256[](2 * k + 2); // 存堆下标
        uint256 cn = 1;
        cand[0] = 0;
        for (uint256 filled = 0; filled < k; filled++) {
            uint256 bi = 0;
            uint256 bestKey = heap[cand[0]];
            for (uint256 j = 1; j < cn; j++) {
                uint256 kk = heap[cand[j]];
                if (kk > bestKey) { bestKey = kk; bi = j; }
            }
            uint256 hs = cand[bi];
            cand[bi] = cand[cn - 1];
            cn--;
            uint256 idx = _keyIdx(bestKey);
            Position storage p = positions[idx];
            uint256 v = quoteSell(p.tokens);
            rows[filled] = QueueRow({
                idx: idx, owner: p.owner, tokens: p.tokens, paid: p.paid,
                value: v, multX1e4: (v * 1e4) / p.paid, boughtAt: p.boughtAt
            });
            uint256 l = (hs << 1) + 1;
            if (l < n && cn < cand.length) { cand[cn] = l; cn++; }
            uint256 r = l + 1;
            if (r < n && cn < cand.length) { cand[cn] = r; cn++; }
            if (cn == 0) { // 堆已取空
                assembly { mstore(rows, add(filled, 1)) }
                return rows;
            }
        }
    }

    /// @notice 某个仓位排第几（1 = 下一个出场）；不在场返回 0。
    /// @dev 堆里没有天然名次，这里线性扫一遍堆数组。eth_call 仍有 gas 上限。
    ///      在场人数超过 maxScan 时返回 0（表示「未计算」，不是第 0 名）。
    ///      可结合 position.status 区分不在场和名次未计算。
    function rankOf(address who, uint256 maxScan) public view returns (uint256) {
        uint256 slot = positionOf[who];
        if (slot == 0) return 0;
        uint256 idx = slot - 1;
        if (positions[idx].status != Status.Live) return 0;
        uint256 n = heap.length;
        if (n > maxScan) return 0;
        uint256 myKey = _key(idx, positions[idx].tokens);
        uint256 rank = 1;
        for (uint256 i = 0; i < n; i++) if (heap[i] > myKey) rank++;
        return rank;
    }

    struct Info {
        bool exists; uint256 idx; uint256 tokens; uint256 paid; uint256 received;
        uint64 boughtAt; uint64 closedAt; uint64 unlockAt; Status status;
        uint256 currentValue; uint256 multX1e4; uint256 queueRank; // Live + 0 = 名次未计算
    }

    function infoOf(address who) external view returns (Info memory i) {
        uint256 slot = positionOf[who];
        if (slot == 0) return i;
        uint256 idx = slot - 1;
        Position storage p = positions[idx];
        i.exists = true; i.idx = idx; i.tokens = p.tokens; i.paid = p.paid; i.received = p.received;
        i.boughtAt = p.boughtAt; i.closedAt = p.closedAt;
        i.unlockAt = uint64(uint256(p.boughtAt) + lockPeriod); i.status = p.status;
        if (p.status == Status.Live) {
            i.currentValue = quoteSell(p.tokens);
            i.multX1e4 = (i.currentValue * 1e4) / p.paid;
            i.queueRank = rankOf(who, INFO_RANK_SCAN_LIMIT);
        }
    }

    /// @notice 还要再进多少张票，队首那个人才会被十倍强卖？
    ///         0 = 已达标（下一笔 settle 就出场）；NONE = maxSim 张之内还到不了。
    /// @dev 纯链下用：把「再来 n 张票」按同一条曲线推演一遍。新买家拿到的币一定少于当前队首，
    ///      所以推演期间队首不会换人。
    function ticketsUntilNextPayout(uint256 maxSim) public view returns (uint256) {
        if (heap.length == 0) return NONE;
        uint256 idx = _keyIdx(heap[0]);
        Position storage p = positions[idx];
        uint256 target = p.paid * targetMult;
        uint256 rn = reserveNative;
        uint256 rt = reserveToken;
        uint256 real = realNative;
        uint256 tk = p.tokens;
        // 🔴 2026-09-21 修（Gemini 对抗审计抓到，我自己漏了）：
        //    一张票只有 (1 - burnBps) 进池，另一部分去 Pons 烧掉了。
        //    原来这里按**票面全额**推演，等于假装曲线涨得比实际快 ——
        //    前端会显示「还差 50 张」而真实要 59 张，到点没出场，用户会认为是操纵。
        //    这不是数值误差，是会让人觉得被骗的那种错，必须按 toPool 推。
        //    取保守方向：假设每次销毁都成功（常态）。销毁失败时钱回落进池，
        //    实际只会比这里预测的**更快**到达，宁可说慢不许说快。
        uint256 toPool = ticket - (ticket * burnBps) / BPS;
        for (uint256 i = 0; i <= maxSim; i++) {
            uint256 out = rn - Math.mulDiv(rn, rt, rt + tk, Math.Rounding.Ceil);
            if (out > real) out = real;
            if (out >= target) return i;
            uint256 minted = rt - Math.mulDiv(rn, rt, rn + toPool, Math.Rounding.Ceil);
            if (minted == 0) return NONE;
            rn += toPool; rt -= minted; real += toPool;
        }
        return NONE;
    }

    struct Stats {
        uint256 ticket; uint256 targetMult; uint256 lockPeriod;
        uint256 reserveNative; uint256 reserveToken; uint256 realNative; uint256 curvePrice;
        uint256 totalPositions; uint256 liveCount; uint256 autoSoldCount; uint256 exitedCount;
        uint256 totalIn; uint256 totalOut;
        uint256 headIdx; address headOwner; uint256 headValue; uint256 headMultX1e4; uint256 headTarget;
        uint256 ticketsToNextPayout;
        // 引擎二
        uint256 burnBps; address ponsCurve; address ponsToken;
        uint256 totalBurnedNative; uint256 totalBurnedTokens; uint256 burnCount; uint256 burnSkipCount;
    }

    function stats() external view returns (Stats memory s) {
        s.ticket = ticket; s.targetMult = targetMult; s.lockPeriod = lockPeriod;
        s.reserveNative = reserveNative; s.reserveToken = reserveToken; s.realNative = realNative;
        s.curvePrice = Math.mulDiv(reserveNative, 1e18, reserveToken);
        s.totalPositions = positions.length; s.liveCount = liveCount;
        s.autoSoldCount = autoSoldCount; s.exitedCount = exitedCount;
        s.totalIn = totalIn; s.totalOut = totalOut;
        s.burnBps = burnBps; s.ponsCurve = address(ponsCurve); s.ponsToken = ponsToken;
        s.totalBurnedNative = totalBurnedNative; s.totalBurnedTokens = totalBurnedTokens;
        s.burnCount = burnCount; s.burnSkipCount = burnSkipCount;
        s.headIdx = head();
        s.ticketsToNextPayout = NONE;
        if (s.headIdx != NONE) {
            Position storage p = positions[s.headIdx];
            s.headOwner = p.owner; s.headValue = quoteSell(p.tokens);
            s.headMultX1e4 = (s.headValue * 1e4) / p.paid; s.headTarget = p.paid * targetMult;
            s.ticketsToNextPayout = ticketsUntilNextPayout(200);
        }
    }

    // ─────────────── 引擎二 · 只读 ───────────────

    struct Spiral {
        uint256 burnBps;              // 每票拿去销毁的比例（基点）
        address ponsCurve;
        address ponsToken;
        address burnSink;
        uint256 totalBurnedNative;    // 累计投进回购的原生币
        uint256 totalBurnedTokens;    // 累计销毁的代币
        uint256 burnCount;
        uint256 burnSkipCount;
        uint256 burnedSupplyBps;      // 已销毁占代币总供应的比例（基点）；读不到供应时为 0
        uint256 ponsQuoteReserve;     // Pons 曲线当前 quote 储备
        uint256 ponsTokenReserve;
        uint256 ponsPrice;            // Pons 边际价：1e18 个币值多少 wei
        bool    ponsGraduated;        // 毕业后曲线关闭，回购这条腿自动停（钱回落进池）
        uint256 burnPerTicket;        // 每张票会销毁掉多少原生币
    }

    /// @notice 螺旋的全部可核验事实，一次 eth_call 取完。全部来自链上状态，不做任何预测。
    /// @dev burnedSupplyBps 用代币的 totalSupply() 实算；读不到就留 0 而不是猜。
    function spiral() external view returns (Spiral memory sp) {
        sp.burnBps = burnBps;
        sp.ponsCurve = address(ponsCurve);
        sp.ponsToken = ponsToken;
        sp.burnSink = BURN_SINK;
        sp.totalBurnedNative = totalBurnedNative;
        sp.totalBurnedTokens = totalBurnedTokens;
        sp.burnCount = burnCount;
        sp.burnSkipCount = burnSkipCount;
        sp.burnPerTicket = (ticket * burnBps) / BPS;
        if (address(ponsCurve) == address(0)) return sp;
        try ponsCurve.getReserves() returns (uint256 q, uint256 t) {
            sp.ponsQuoteReserve = q;
            sp.ponsTokenReserve = t;
            if (t != 0) sp.ponsPrice = Math.mulDiv(q, 1e18, t);
        } catch {}
        try ponsCurve.graduated() returns (bool g) { sp.ponsGraduated = g; } catch {}
        try IERC20Supply(ponsToken).totalSupply() returns (uint256 ts) {
            if (ts != 0) sp.burnedSupplyBps = Math.mulDiv(totalBurnedTokens, BPS, ts);
        } catch {}
    }

    /// @notice 钱的恒等式：进 = 出 + 池中余额 + 已销毁。任何人可随时核。
    /// @dev 这是本合约最重要的不变式，测试里每个用例结束都查它。
    function solvent() external view returns (bool ok, uint256 inAmt, uint256 outAmt, uint256 pool, uint256 burnedAmt) {
        inAmt = totalIn; outAmt = totalOut; pool = realNative; burnedAmt = totalBurnedNative;
        ok = (inAmt == outAmt + pool + burnedAmt) && (address(this).balance >= pool + totalPending);
    }
}

interface IERC20Supply { function totalSupply() external view returns (uint256); }
