// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// ERC20 代幣的標準介面，定義了轉帳功能
interface IERC20 {
    // 從合約轉帳給指定地址
    function transfer(address, uint256) external returns (bool);

    // 從一個地址轉帳到另一個地址（需要授權）
    function transferFrom(address, address, uint256) external returns (bool);
}

// 部署测试
// 账户 1（deployer）：-> launch（發起眾籌）
// 账户 2 -> pledge（認捐）
// 账户 3 -> pledge（認捐）

/**
 * 眾籌合約
 * 功能：用戶可以發起眾籌專案，其他人可以認捐代幣
 * 如果達到目標金額，創建者可以提取資金
 * 如果未達到目標，認捐者可以退款
 */
contract CrowdFund {
    // ========== 事件定義 ==========
    // 這些事件會在對應操作發生時被觸發，用於記錄和通知

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
    // 認捐時觸發
    event Pledge(uint indexed id, address indexed caller, uint amount);
    // 撤回認捐時觸發
    event Unpledge(uint indexed id, address indexed caller, uint amount);
    // 創建者提取資金時觸發
    event Claim(uint id);
    // 退款時觸發
    event Refund(uint indexed id, address indexed caller, uint amount);

    // ========== 資料結構定義 ==========

    // 眾籌活動的資料結構
    struct Campaign {
        address creator; // 眾籌創建者的地址
        uint goal; // 眾籌目標金額
        uint pledged; // 目前已認捐的總金額
        uint32 startAt; // 眾籌開始時間（時間戳）
        uint32 endAt; // 眾籌結束時間（時間戳）
        bool claimed; // 是否已被創建者提取資金
    }

    // ========== 狀態變數 ==========

    // 使用的 ERC20 代幣合約地址（部署後不可更改）
    IERC20 public immutable token;

    // 眾籌活動的總數量（也作為下一個活動的 ID）
    uint public count;

    // 儲存所有眾籌活動：活動ID -> 活動資料
    mapping(uint => Campaign) public campaigns;

    // 記錄每個用戶對每個活動的認捐金額：活動ID -> 用戶地址 -> 認捐金額
    mapping(uint => mapping(address => uint)) public pledgedAmount;

    // ========== 建構函數 ==========

    /**
     * 部署合約時執行，設定要使用的代幣合約地址
     * @param _token ERC20 代幣合約的地址
     */
    constructor(address _token) {
        token = IERC20(_token);
    }

    // ========== 主要功能函數 ==========

    /**
     * 發起眾籌活動
     * @param _goal 眾籌目標金額
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
        // 檢查眾籌持續時間不能超過30天
        require(_endOffset <= 30 days, "end > 30 days");

        // 計算實際的開始和結束時間戳
        uint32 _startAt = uint32(block.timestamp) + _startOffset;
        uint32 _endAt = uint32(block.timestamp) + _endOffset;

        // 活動計數器加1，作為新活動的ID
        count += 1;

        // 創建新的眾籌活動
        campaigns[count] = Campaign({
            creator: msg.sender, // 設定創建者為當前調用者
            goal: _goal,
            pledged: 0, // 初始認捐金額為0
            startAt: _startAt,
            endAt: _endAt,
            claimed: false // 初始狀態為未提取
        });

        // 觸發發起眾籌事件
        emit Launch(count, msg.sender, _goal, _startAt, _endAt);
    }

    /**
     * 取消眾籌活動（只有創建者可以在開始前取消）
     * @param _id 眾籌活動的ID
     */
    function cancel(uint _id) external {
        // 讀取活動資料（使用memory節省gas）
        Campaign memory campaign = campaigns[_id];

        // 檢查只有創建者可以取消
        require(msg.sender == campaign.creator, "not creator");
        // 檢查只能在活動開始前取消
        require(block.timestamp < campaign.startAt, "started");

        // 刪除活動資料
        delete campaigns[_id];
        // 觸發取消事件
        emit Cancel(_id);
    }

    /**
     * 認捐資金
     * @param _id 眾籌活動的ID
     * @param _amount 認捐金額
     */
    function pledge(uint _id, uint _amount) external {
        // 讀取活動資料（使用storage因為要修改）
        Campaign storage campaign = campaigns[_id];

        // 檢查眾籌活動是否已經開始
        require(block.timestamp >= campaign.startAt, "not started");
        // 檢查眾籌活動是否還在進行中
        require(block.timestamp <= campaign.endAt, "ended");

        // 增加活動的總認捐金額
        campaign.pledged += _amount;
        // 記錄用戶的認捐金額
        pledgedAmount[_id][msg.sender] += _amount;

        // 將代幣從用戶轉到合約（需要用戶事先授權）
        token.transferFrom(msg.sender, address(this), _amount);
        // 觸發認捐事件
        emit Pledge(_id, msg.sender, _amount);
    }

    /**
     * 撤回認捐（在眾籌結束前可以撤回）
     * @param _id 眾籌活動的ID
     * @param _amount 撤回金額
     */
    function unpledge(uint _id, uint _amount) external {
        // 讀取活動資料
        Campaign storage campaign = campaigns[_id];

        // 檢查眾籌活動還沒結束
        require(block.timestamp <= campaign.endAt, "ended");

        // 減少活動的總認捐金額
        campaign.pledged -= _amount;
        // 減少用戶的認捐金額記錄
        pledgedAmount[_id][msg.sender] -= _amount;

        // 將代幣退還給用戶
        token.transfer(msg.sender, _amount);
        // 觸發撤回認捐事件
        emit Unpledge(_id, msg.sender, _amount);
    }

    /**
     * 提取資金（只有創建者在眾籌成功後可以提取）
     * @param _id 眾籌活動的ID
     */
    function claim(uint _id) external {
        // 讀取活動資料
        Campaign storage campaign = campaigns[_id];

        // 檢查只有創建者可以提取
        require(msg.sender == campaign.creator, "not creator");
        // 檢查眾籌活動已經結束
        require(block.timestamp > campaign.endAt, "not ended");
        // 檢查認捐金額達到目標
        require(campaign.pledged >= campaign.goal, "pledged < goal");
        // 檢查還沒被提取過
        require(!campaign.claimed, "claimed");

        // 標記為已提取，防止重複提取
        campaign.claimed = true;

        // 將所有認捐資金轉給創建者
        token.transfer(msg.sender, campaign.pledged);
        // 觸發提取資金事件
        emit Claim(_id);
    }

    /**
     * 失敗退款（眾籌失敗後，認捐者可以申請退款）
     * @param _id 眾籌活動的ID
     */
    function refund(uint _id) external {
        // 讀取活動資料
        Campaign storage campaign = campaigns[_id];

        // 檢查眾籌活動已經結束
        require(block.timestamp > campaign.endAt, "not ended");
        // 檢查認捐金額未達到目標（眾籌失敗）
        require(campaign.pledged < campaign.goal, "pledged >= goal");

        // 取得用戶的認捐金額
        uint bal = pledgedAmount[_id][msg.sender];
        // 將用戶的認捐記錄清零（防止重複退款）
        pledgedAmount[_id][msg.sender] = 0;

        // 退還代幣給用戶
        token.transfer(msg.sender, bal);
        // 觸發退款事件
        emit Refund(_id, msg.sender, bal);
    }
}
