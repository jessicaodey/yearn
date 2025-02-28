// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract YearnVault {
    struct StrategyParams {
        uint256 activation;
        uint256 lastReport;
        uint256 currentDebt;
        uint256 maxDebt;
    }

    event StrategyChanged(address indexed strategy, StrategyChangeType changeType);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt,
        uint256 protocolFees,
        uint256 totalFees,
        uint256 totalRefunds
    );
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);
    event Shutdown();

    enum Roles {
        ADD_STRATEGY_MANAGER,
        REVOKE_STRATEGY_MANAGER,
        FORCE_REVOKE_MANAGER,
        ACCOUNTANT_MANAGER,
        QUEUE_MANAGER,
        REPORTING_MANAGER,
        DEBT_MANAGER,
        MAX_DEBT_MANAGER,
        DEPOSIT_LIMIT_MANAGER,
        WITHDRAW_LIMIT_MANAGER,
        MINIMUM_IDLE_MANAGER,
        PROFIT_UNLOCK_MANAGER,
        DEBT_PURCHASER,
        EMERGENCY_MANAGER
    }

    enum StrategyChangeType {
        ADDED,
        REVOKED
    }

    uint256 public constant MAX_QUEUE = 10;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    address public asset;
    uint8 public decimals;
    address public factory;
    mapping(address => StrategyParams) public strategies;
    address[] public defaultQueue;
    bool public useDefaultQueue;
    uint256 public totalDebt;
    uint256 public totalIdle;
    uint256 public minimumTotalIdle;
    bool public shutdown;
    uint256 public profitMaxUnlockTime;
    uint256 public fullProfitUnlockDate;
    uint256 public profitUnlockingRate;
    uint256 public lastProfitUpdate;

    constructor() {
        asset = address(this);
    }

    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager,
        uint256 _profitMaxUnlockTime
    ) external {
        require(asset == address(0), "initialized");
        asset = _asset;
        decimals = IERC20Metadata(_asset).decimals();
        factory = msg.sender;
        profitMaxUnlockTime = _profitMaxUnlockTime;
        roleManager = _roleManager;
    }

    function _addStrategy(address newStrategy, bool addToQueue) internal {
        require(newStrategy != address(0) && newStrategy != address(this), "invalid strategy");
        strategies[newStrategy] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: 0
        });
        if (addToQueue && defaultQueue.length < MAX_QUEUE) {
            defaultQueue.push(newStrategy);
        }
        emit StrategyChanged(newStrategy, StrategyChangeType.ADDED);
    }

    function _revokeStrategy(address strategy, bool force) internal {
        require(strategies[strategy].activation != 0, "strategy not active");
        uint256 loss = force ? strategies[strategy].currentDebt : 0;
        if (loss > 0) {
            totalDebt -= loss;
        }
        delete strategies[strategy];
        for (uint256 i = 0; i < defaultQueue.length; i++) {
            if (defaultQueue[i] == strategy) {
                defaultQueue[i] = defaultQueue[defaultQueue.length - 1];
                defaultQueue.pop();
                break;
            }
        }
        emit StrategyChanged(strategy, StrategyChangeType.REVOKED);
    }

    function _updateDebt(
        address strategy,
        uint256 targetDebt,
        uint256 maxLoss
    ) internal returns (uint256) {
        uint256 currentDebt = strategies[strategy].currentDebt;
        if (currentDebt > targetDebt) {
            uint256 assetsToWithdraw = currentDebt - targetDebt;
            uint256 preBalance = IERC20(asset).balanceOf(address(this));
            _withdrawFromStrategy(strategy, assetsToWithdraw);
            uint256 postBalance = IERC20(asset).balanceOf(address(this));
            uint256 withdrawn = postBalance - preBalance;
            totalIdle += withdrawn;
            totalDebt -= assetsToWithdraw;
            currentDebt -= assetsToWithdraw;
        } else {
            uint256 assetsToDeposit = targetDebt - currentDebt;
            IERC20(asset).approve(strategy, assetsToDeposit);
            IStrategy(strategy).deposit(assetsToDeposit, address(this));
            totalIdle -= assetsToDeposit;
            totalDebt += assetsToDeposit;
            currentDebt += assetsToDeposit;
        }
        strategies[strategy].currentDebt = currentDebt;
        emit DebtUpdated(strategy, currentDebt, currentDebt);
        return currentDebt;
    }

    function _processReport(address strategy) internal returns (uint256, uint256) {
        uint256 strategyShares = IStrategy(strategy).balanceOf(address(this));
        uint256 totalAssets = IStrategy(strategy).convertToAssets(strategyShares);
        uint256 currentDebt = strategies[strategy].currentDebt;
        uint256 gain = totalAssets > currentDebt ? totalAssets - currentDebt : 0;
        uint256 loss = totalAssets < currentDebt ? currentDebt - totalAssets : 0;
        if (gain > 0) {
            strategies[strategy].currentDebt = currentDebt + gain;
            totalDebt += gain;
        } else if (loss > 0) {
            strategies[strategy].currentDebt = currentDebt - loss;
            totalDebt -= loss;
        }
        strategies[strategy].lastReport = block.timestamp;
        emit StrategyReported(strategy, gain, loss, strategies[strategy].currentDebt, 0, 0, 0);
        return (gain, loss);
    }

    function _unlockedShares() internal view returns (uint256) {
        if (fullProfitUnlockDate > block.timestamp) {
            return (profitUnlockingRate * (block.timestamp - lastProfitUpdate)) / MAX_BPS_EXTENDED;
        } else if (fullProfitUnlockDate != 0) {
            return IERC20(address(this)).balanceOf(address(this));
        }
        return 0;
    }

    function shutdownVault() external {
        require(hasRole(Roles.EMERGENCY_MANAGER, msg.sender), "not allowed");
        shutdown = true;
        emit Shutdown();
    }
}