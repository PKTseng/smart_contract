// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// ERC20 代幣標準介面，定義了代幣轉帳的基本功能
interface IERC20 {
    // 轉帳代幣給指定地址
    function transfer(address, uint256) external returns (bool);

    // 從一個地址轉帳代幣到另一個地址（需要事先授權）
    function transferFrom(address, address, uint256) external returns (bool);
}

// 部署測試說明：
// 帳戶 1（部署者）：發起眾籌 -> launch
// 帳戶 2：參與投資 -> pledge
// 帳戶 3：參與投資 -> pledge

contract CrowdFund {
    // ===== 事件定義 =====
    // 這些事件會在對應操作執行時發出，用於記錄和通知

    // 發起眾籌時觸發
    event Launch(
        uint id,
        address indexed creator,
        uint goal,
        uint32 startAt,
        uint32 endAt
    );
    // 取消眾籌時觸發
    event Cancel(uint id);
    // 認捐資金時觸發
    event Pledge(uint indexed id, address indexed caller, uint amount);
    // 撤回認捐時觸發
    event Unpledge(uint indexed id, address indexed caller, uint amount);
    // 提取資金時觸發（眾籌成功後）
    event Claim(uint id);
    // 退款時觸發（眾籌失敗後）
    event Refund(uint indexed id, address indexed caller, uint amount);

    // ===== 數據結構定義 =====

    // 眾籌活動的數據結構
    struct Campaign {
        address creator; // 發起人地址
        uint goal; // 目標籌款金額
        uint pledged; // 已籌集金額
        uint32 startAt; // 開始時間（Unix 時間戳）
        uint32 endAt; // 結束時間（Unix 時間戳）
        bool claimed; // 是否已提取資金（防止重複提取）
    }

    // ===== 狀態變量 =====

    // 使用的 ERC20 代幣合約地址（immutable 表示部署後不可更改）
    IERC20 public immutable token;

    // 眾籌活動總數計數器
    uint public count;

    // 存储所有眾籌活動：活動ID => 活動信息
    mapping(uint => Campaign) public campaigns;

    // 記錄每個用戶對每個活動的認捐金額：活動ID => 用戶地址 => 認捐金額
    mapping(uint => mapping(address => uint)) public pledgedAmount;

    // ===== 構造函數 =====

    // 部署合約時設定要使用的代幣地址
    constructor(address _token) {
        token = IERC20(_token);
    }

    // ===== 主要功能函數 =====

    /**
     * 發起眾籌活動
     * @param _goal 目標籌款金額
     * @param _startOffset 從現在開始多少秒後開始眾籌
     * @param _endOffset 從現在開始多少秒後結束眾籌
     */
    function launch(
        uint _goal,
        uint32 _startOffset,
        uint32 _endOffset
    ) external {
        // 檢查結束時間必須晚於開始時間
        require(_endOffset > _startOffset, "endAt <= startAt");
        // 檢查眾籌期間不能超過30天
        require(_endOffset <= 30 days, "end > 30 days");

        // 計算實際的開始和結束時間戳
        uint32 _startAt = uint32(block.timestamp) + _startOffset;
        uint32 _endAt = uint32(block.timestamp) + _endOffset;

        // 活動計數器加1
        count += 1;

        // 創建新的眾籌活動
        campaigns[count] = Campaign({
            creator: msg.sender, // 發起人是調用此函數的地址
            goal: _goal,
            pledged: 0, // 初始認捐金額為0
            startAt: _startAt,
            endAt: _endAt,
            claimed: false // 初始未提取資金
        });

        // 發出事件通知
        emit Launch(count, msg.sender, _goal, _startAt, _endAt);
    }

    /**
     * 取消眾籌活動（只有發起人在活動開始前可以取消）
     * @param _id 要取消的活動ID
     */
    function cancel(uint _id) external {
        Campaign memory campaign = campaigns[_id];

        // 檢查只有發起人可以取消
        require(msg.sender == campaign.creator, "not creator");
        // 檢查活動還未開始
        require(block.timestamp < campaign.startAt, "started");

        // 刪除活動數據
        delete campaigns[_id];
        emit Cancel(_id);
    }

    /**
     * 認捐資金
     * @param _id 要認捐的活動ID
     * @param _amount 認捐金額
     */
    function pledge(uint _id, uint _amount) external {
        // 獲取活動信息（storage 表示直接修改原數據）
        Campaign storage campaign = campaigns[_id];

        // 檢查活動已經開始
        require(block.timestamp >= campaign.startAt, "not started");
        // 檢查活動還未結束
        require(block.timestamp <= campaign.endAt, "ended");

        // 更新總認捐金額
        campaign.pledged += _amount;
        // 更新用戶對此活動的認捐金額
        pledgedAmount[_id][msg.sender] += _amount;

        // 從用戶轉帳代幣到合約
        token.transferFrom(msg.sender, address(this), _amount);
        emit Pledge(_id, msg.sender, _amount);
    }

    /**
     * 撤回認捐（在活動結束前可以撤回）
     * @param _id 活動ID
     * @param _amount 要撤回的金額
     */
    function unpledge(uint _id, uint _amount) external {
        Campaign storage campaign = campaigns[_id];

        // 檢查活動還未結束
        require(block.timestamp <= campaign.endAt, "ended");

        // 更新總認捐金額（減少）
        campaign.pledged -= _amount;
        // 更新用戶認捐金額（減少）
        pledgedAmount[_id][msg.sender] -= _amount;

        // 將代幣退還給用戶
        token.transfer(msg.sender, _amount);
        emit Unpledge(_id, msg.sender, _amount);
    }

    /**
     * 提取資金（眾籌成功後，發起人可以提取所有資金）
     * @param _id 活動ID
     */
    function claim(uint _id) external {
        Campaign storage campaign = campaigns[_id];

        // 檢查只有發起人可以提取
        require(msg.sender == campaign.creator, "not creator");
        // 檢查活動已經結束
        require(block.timestamp > campaign.endAt, "not ended");
        // 檢查達到了籌款目標
        require(campaign.pledged >= campaign.goal, "pledged < goal");
        // 檢查還未提取過資金
        require(!campaign.claimed, "claimed");

        // 標記為已提取
        campaign.claimed = true;
        // 將所有認捐資金轉給發起人
        token.transfer(msg.sender, campaign.pledged);
        emit Claim(_id);
    }

    /**
     * 退款（眾籌失敗後，認捐者可以取回自己的資金）
     * @param _id 活動ID
     */
    function refund(uint _id) external {
        Campaign storage campaign = campaigns[_id];

        // 檢查活動已經結束
        require(block.timestamp > campaign.endAt, "not ended");
        // 檢查未達到籌款目標（眾籌失敗）
        require(campaign.pledged < campaign.goal, "pledged >= goal");

        // 獲取用戶在此活動中的認捐金額
        uint bal = pledgedAmount[_id][msg.sender];
        // 清零用戶認捐記錄（防止重複退款）
        pledgedAmount[_id][msg.sender] = 0;

        // 退還代幣給用戶
        token.transfer(msg.sender, bal);
        emit Refund(_id, msg.sender, bal);
    }
}
