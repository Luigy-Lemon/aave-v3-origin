// SPDX-License-Identifier: agpl-3
pragma solidity ^0.8.19;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IYieldMaestro} from './interfaces/IYieldMaestro.sol';

contract YieldMaestro is Initializable, IYieldMaestro {
  /// @notice Address of the GHO token contract.
  IERC20 public GHO;
  /// @notice Address of the Aave AccessControlList (ACL) Manager contract.
  IAccessControl internal aclManager;

  /// @notice Address of the sGHO (Staked GHO) token contract, which acts as the vault.
  address public sGHO;
  /// @notice Timestamp of the last time savings were claimed by the sGHO vault.
  uint256 public lastClaimTimestamp;
  /// @notice The target Annual Percentage Rate (APR) for yield distribution, scaled by `RATE_PRECISION` (1e10).
  /// @dev For example, with a 10% APR (true rate of 0.1), `targetRate` is `0.1 * RATE_PRECISION = 1e9`. This occurs if `setTargetRate` is called with `newRate = 1000`.
  uint256 public targetRate;

  /// @dev Precision for rate calculations (10^10).
  uint256 internal constant RATE_PRECISION = 1e10;
  /// @dev Number of seconds in one year (365 days).
  uint256 internal constant ONE_YEAR = 365 days;

  /// @notice Role identifier for funds administration.
  bytes32 public constant FUNDS_ADMIN_ROLE = 'FUNDS_ADMIN';
  /// @notice Role identifier for yield management.
  bytes32 public constant YIELD_MANAGER_ROLE = 'YIELD_MANAGER';

  /**
   * @notice Initializes the contract with the GHO token and ACL manager addresses.
   * @param _gho The address of the GHO token contract.
   * @param _aclmanager The address of the Aave AccessControlList (ACL) Manager contract.
   * @param _sGho The address of the sGHO (Staked GHO) token contract (the vault).
   * @custom:oz-upgrades-unsafe-allow payable
   */
  function initialize(address _gho, address _aclmanager, address _sGho) public payable initializer {
    GHO = IERC20(_gho);
    aclManager = IAccessControl(_aclmanager);
    sGHO = _sGho;
    lastClaimTimestamp = block.timestamp;
    targetRate = 0;
  }

  /**
   * @dev Throws if the contract is not initialized.
   */
  modifier isInitialized() {
    if (_getInitializedVersion() == 0) {
      revert NotInitialized();
    }
    _;
  }

  /**
   * @dev Throws if the caller does not have the YIELD_MANAGER role.
   * @notice Only accounts with the `YIELD_MANAGER_ROLE` can call this function.
   */
  modifier onlyYieldManager() {
    if (_onlyYieldManager() == false) {
      revert OnlyYieldManager();
    }
    _;
  }

  /**
   * @dev Throws if the caller does not have the FUNDS_ADMIN role.
   * @notice Only accounts with the `FUNDS_ADMIN_ROLE` can call this function.
   */
  modifier onlyFundsAdmin() {
    if (_onlyFundsAdmin() == false) {
      revert OnlyFundsAdmin();
    }
    _;
  }

  /**
   * @dev Throws if the caller is not the sGHO vault.
   * @notice Only the configured sGHO vault can call this function.
   */
  modifier onlyVault() {
    if (_onlyVault() == false) {
      revert OnlyVault();
    }
    _;
  }

  /**
   * @notice Called by the sGHO vault to claim accumulated GHO yield.
   * @dev Transfers the calculated unclaimed GHO to the sGHO vault.
   * If the available GHO balance is less than the unclaimed amount, it transfers the available balance
   * and sets the `targetRate` to 0 to prevent further claims until a new rate is set.
   * Updates `lastClaimTimestamp` after the operation.
   * @return claimed The amount of GHO tokens transferred to the sGHO vault.
   * Emits a {Claimed} event with the amount claimed.
   */
  function claimSavings() public isInitialized onlyVault() returns (uint256 claimed) {
    // if targetRate is 0 skip it
    if (targetRate > 0) {
      uint256 unclaimed = _calculateUnclaimed();
      uint256 availableBalance = GHO.balanceOf(address(this));
      
      claimed = unclaimed;
      // if available balance is less than unclaimed, set targetRate to 0
      if (availableBalance < unclaimed) {
        claimed = availableBalance;
        targetRate = 0;
      }

      if (claimed > 0) {
        GHO.transfer(sGHO, claimed);
        emit Claimed(claimed);
      }
    }
    lastClaimTimestamp = block.timestamp;
  }

  /**
   * @dev Internal view function to calculate the amount of GHO yield pending to be claimed.
   * Calculates based on `sGHO.totalAssets()`, `targetRate`, and time elapsed since `lastClaimTimestamp`.
   * @return The amount of unclaimed GHO yield.
   */
  function _calculateUnclaimed() public view returns (uint256) {
    // Calculate the time elapsed since the last claim
    uint256 elapsedTime = block.timestamp - lastClaimTimestamp;
    uint256 vaultAssets = IERC4626(sGHO).totalAssets();

    // Calculate unclaimed rewards based on targetRate
    uint256 unclaimedRewards = (vaultAssets * targetRate * elapsedTime) /
      (RATE_PRECISION * ONE_YEAR);
    return unclaimedRewards;
  }

  /**
   * @dev Preview how much would be claimable
   * @notice Returns the amount of GHO yield currently claimable by the sGHO vault.
   * @return claimable The amount of GHO that can be claimed.
   */
  function previewClaimable() external view returns (uint256 claimable) {
    claimable = _calculateUnclaimed();
  }

  /**
   * @dev Calculates the vault's current target APR based on `targetRate`. sGHO is the relevant asset.
   * @notice Returns the current target Annual Percentage Rate (APR) of the sGHO vault.
   * @return The target APR, where a value of 1000 represents 10% APR (effectively `targetRate / 1e6`).
   */
  function vaultAPR() external view returns (uint256) {
    return targetRate / 1e6;
  }

  /**
   * @dev set new target rate in APR, such that a target rate of 10% should have input 1000
   * @notice Sets a new target Annual Percentage Rate (APR) for yield distribution.
   * @param newRate The new target APR. For example, for 10% APR, `newRate` should be 1000.
   *        This `newRate` is multiplied by `1e6` to set the internal `targetRate` (which adheres to `trueRate * RATE_PRECISION`).
   */
  function setTargetRate(uint256 newRate) public onlyYieldManager {
    targetRate = newRate * 1e6;
  }

  /**
   * @notice Allows a funds admin to rescue ERC20 tokens mistakenly sent to this contract.
   * @dev Transfers the specified amount of an ERC20 token to a designated address.
   * If the requested amount is greater than the contract's balance of the token, it transfers the entire balance.
   * @param erc20Token The address of the ERC20 token to rescue.
   * @param to The address to send the rescued tokens to.
   * @param amount The amount of tokens to rescue.
   * Emits an {ERC20Rescued} event.
   */
  function rescueERC20(address erc20Token, address to, uint256 amount) external onlyFundsAdmin {
    uint256 max = IERC20(erc20Token).balanceOf(address(this));
    amount = max > amount ? amount : max;
    IERC20(erc20Token).transfer(to, amount);
    emit ERC20Rescued(msg.sender, erc20Token, to, amount);
  }

  /**
   * @dev Prevents direct ETH transfers to the contract.
   * @notice Reverts if ETH is sent to the contract.
   */
  receive() external payable {
    revert NoEthAllowed();
  }

  /**
   * @dev Internal view function to check if the caller has the `FUNDS_ADMIN_ROLE`.
   * @return True if the caller has the role, false otherwise.
   */
  function _onlyFundsAdmin() internal view returns (bool) {
    return aclManager.hasRole(FUNDS_ADMIN_ROLE, msg.sender);
  }

  /**
   * @dev Internal view function to check if the caller has the `YIELD_MANAGER_ROLE`.
   * @return True if the caller has the role, false otherwise.
   */
  function _onlyYieldManager() internal view returns (bool) {
    return aclManager.hasRole(YIELD_MANAGER_ROLE, msg.sender);
  }

  /**
   * @dev Internal view function to check if the caller is the sGHO vault.
   * @return True if `msg.sender` is the configured `sGHO` address, false otherwise.
   */
  function _onlyVault() internal view returns (bool) {
    return msg.sender == sGHO;
  }
}
