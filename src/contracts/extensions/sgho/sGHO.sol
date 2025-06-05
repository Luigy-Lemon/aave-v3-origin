// SPDX-License-Identifier: agpl-3
pragma solidity ^0.8.19;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {IYieldMaestro} from './interfaces/IYieldMaestro.sol';
import {IStakedToken} from '../../../contracts/rewards/interfaces/IStakedToken.sol';

interface IERC1271 {
  function isValidSignature(bytes32, bytes memory) external view returns (bytes4);
}

contract sGHO is Initializable, ERC4626Upgradeable, ERC20PermitUpgradeable, IStakedToken {
  /// @notice Address of the GHO token
  address public gho;
  /// @notice Address of the YieldMaestro contract
  address public YIELD_MAESTRO;
  /// @notice The total amount of GHO tokens held by the contract.
  uint256 internal internalTotalAssets;
  /// @notice Timestamp of the last time savings were claimed.
  uint256 internal lastupdate;

  /// @inheritdoc IStakedToken
  address public STAKED_TOKEN;

  // --- EIP712 niceties ---
  uint256 public immutable deploymentChainId;
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
  string public constant VERSION = '1';

  /**
   * @dev Invalid signature.
   */
  error InvalidSignature();

  /**
   * @dev Thrown when a direct ETH transfer is attempted.
   */
  error NoEthAllowed();

  /**
   * @dev Constructor for the sGHO contract.
   */
  constructor() {
    deploymentChainId = block.chainid;
    lastupdate = block.timestamp;
  }

  /**
   * @dev Set the underlying asset contract. This must be an ERC20-compatible contract (ERC20 or ERC777).
   * @param _gho The address of the GHO token contract.
   * @param _yieldMaestro The address of the Yield Maestro contract.
   */
  function initialize(
    address _gho,
    address _yieldMaestro
  ) public initializer {
    __ERC20_init('sGHO', 'sGHO');
    __ERC4626_init(IERC20(_gho));
    __ERC20Permit_init('sGHO');
    gho = _gho;
    STAKED_TOKEN = _gho;
    YIELD_MAESTRO = _yieldMaestro;
  }

  /**
   * @dev Prevents direct ETH transfers to the contract.
   * @notice Reverts if ETH is sent to the contract.
   */
  receive() external payable {
    revert NoEthAllowed();
  }

  // --- IStakedToken Implementation ---
  // @dev This is intended for backwards compatibility with the stkGHO contract and easy integration with the User Interface.

  /// @inheritdoc IStakedToken
  /// @notice Stakes GHO tokens in exchange for sGHO shares. Alias for {deposit}.
  /// @param to The address that will receive the sGHO shares.
  /// @param amount The amount of GHO to stake.
  function stake(address to, uint256 amount) external {
    deposit(amount, to);
  }

  /// @inheritdoc IStakedToken
  /// @notice Redeems sGHO shares for GHO tokens. Alias for {withdraw}.
  /// @param to The address that will receive the GHO tokens.
  /// @param amount The amount of sGHO shares to redeem.
  function redeem(address to, uint256 amount) external {
    withdraw(amount, to, msg.sender);
  }

  /// @inheritdoc IStakedToken
  /// @notice Claims accumulated savings from the YieldMaestro contract.
  /// @dev The `to` and `amount` parameters are unused in this implementation. Intent is Backwards compatibility.
  /// @param to The address to send rewards to (unused).
  /// @param amount The amount of rewards to claim (unused).
  function claimRewards(address to, uint256 amount) external {
    _claimSavings();
  }

  /// @inheritdoc IStakedToken
  /// @notice Initiates the cooldown period for unstaking.
  /// @dev This function is currently a no-op. Intent is Backwards compatibility.
  function cooldown() external {}

  // --- Approve by signature ---

  /**
   * @dev Internal function to validate a signature. Supports both ECDSA and ERC1271.
   * @param signer The address of the signer.
   * @param digest The hash of the message that was signed.
   * @param signature The signature bytes.
   * @return True if the signature is valid, false otherwise.
   */
  function _isValidSignature(
    address signer,
    bytes32 digest,
    bytes memory signature
  ) internal view returns (bool) {
    if (signature.length == 65) {
      bytes32 r;
      bytes32 s;
      uint8 v;
      assembly {
        r := mload(add(signature, 0x20))
        s := mload(add(signature, 0x40))
        v := byte(0, mload(add(signature, 0x60)))
      }
      if (signer == ecrecover(digest, v, r, s)) {
        return true;
      }
    }

    (bool success, bytes memory result) = signer.staticcall(
      abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
    );
    return (success &&
      result.length == 32 &&
      abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector);
  }

  /**
   * @notice Approves the spender to spend the owner's tokens via a signed message.
   * @dev See {IERC20Permit-permit}.
   * @param owner The address of the token owner.
   * @param spender The address of the spender.
   * @param value The amount of tokens to approve.
   * @param deadline The deadline after which the signature is no longer valid.
   * @param signature The signature bytes.
   */
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    bytes memory signature
  ) public {
    if (block.timestamp > deadline) {
      revert ERC2612ExpiredSignature(deadline);
    }

    if (owner == address(0)) {
      revert ERC2612InvalidSigner(owner, spender);
    }

    uint256 nonce = _useNonce(owner);

    bytes32 currentDomainSeparator = _calculateDomainSeparator(block.chainid);

    bytes32 digest = keccak256(
      abi.encodePacked(
        '\x19\x01',
        currentDomainSeparator,
        keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
      )
    );

    if (!_isValidSignature(owner, digest, signature)) {
      revert InvalidSignature();
    }

    _approve(owner, spender, value);
    emit Approval(owner, spender, value);
  }

  /**
   * @notice Approves the spender to spend the owner's tokens via a signed message (with v, r, s parameters).
   * @dev See {IERC20Permit-permit}.
   * @param owner The address of the token owner.
   * @param spender The address of the spender.
   * @param value The amount of tokens to approve.
   * @param deadline The deadline after which the signature is no longer valid.
   * @param v The recovery ID of the signature.
   * @param r The r-value of the signature.
   * @param s The s-value of the signature.
   */
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public virtual override(ERC20PermitUpgradeable) {
    bytes memory signature = abi.encodePacked(r, s, v);
    permit(owner, spender, value, deadline, signature);
  }

  /**
   * @dev See {IERC20Permit-nonces}.
   */
  function nonces(address owner) public view virtual override(ERC20PermitUpgradeable) returns (uint256) {
    return super.nonces(owner);
  }

  /**
   * @dev See {IERC20Permit-DOMAIN_SEPARATOR}.
   */
  function DOMAIN_SEPARATOR() external view virtual override(ERC20PermitUpgradeable) returns (bytes32) {
    return _domainSeparatorV4();
  }

  /**
   * @dev Calculates the EIP712 domain separator.
   * @param chainId The chain ID for which to calculate the separator.
   * @return The EIP712 domain separator.
   */
  function _calculateDomainSeparator(uint256 chainId) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
          ),
          keccak256(bytes(name())),
          keccak256(bytes(VERSION)),
          chainId,
          address(this)
        )
      );
  }

  /**
   * @dev Returns the number of decimals used to get its user representation.
   * @inheritdoc ERC20Upgradeable
   * @return The number of decimals (18).
   */
  function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
    return super.decimals();
  }

  // --- ERC4626 Logic ---

  /**
   * @notice Deposits GHO tokens into the vault and mints sGHO shares to the receiver.
   * @dev See {ERC4626-deposit}.
   * @param assets The amount of GHO to deposit.
   * @param receiver The address that will receive the sGHO shares.
   * @return shares The amount of sGHO shares minted.
   */
  function deposit(uint256 assets, address receiver) public override returns (uint256) {
    uint256 maxAssets = maxDeposit(receiver);
    if (assets > maxAssets) {
      revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
    }

    uint256 shares = previewDeposit(assets);
    _updateVault(assets, true);
    _deposit(_msgSender(), receiver, assets, shares);

    return shares;
  }

  /**
   * @notice Mints sGHO shares to the receiver by depositing a calculated amount of GHO tokens.
   * @dev See {ERC4626-mint}.
   * @param shares The amount of sGHO shares to mint.
   * @param receiver The address that will receive the sGHO shares.
   * @return assets The amount of GHO tokens deposited.
   */
  function mint(uint256 shares, address receiver) public override returns (uint256) {
    uint256 maxShares = maxMint(receiver);
    if (shares > maxShares) {
      revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
    }

    uint256 assets = previewMint(shares);
    _updateVault(assets, true);

    _deposit(_msgSender(), receiver, assets, shares);

    return assets;
  }

  /**
   * @notice Withdraws GHO tokens from the vault by redeeming sGHO shares from the owner.
   * @dev See {ERC4626-withdraw}.
   * @param assets The amount of GHO to withdraw.
   * @param receiver The address that will receive the GHO tokens.
   * @param owner The address from which to redeem sGHO shares.
   * @return shares The amount of sGHO shares redeemed.
   */
  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override returns (uint256) {
    uint256 maxAssets = maxWithdraw(owner);
    if (assets > maxAssets) {
      revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
    }

    uint256 shares = previewWithdraw(assets);
    _withdraw(_msgSender(), receiver, owner, assets, shares);

    _updateVault(assets, false);

    return shares;
  }

  /**
   * @notice Redeems sGHO shares from the owner for GHO tokens.
   * @dev See {ERC4626-redeem}.
   * @param shares The amount of sGHO shares to redeem.
   * @param receiver The address that will receive the GHO tokens.
   * @param owner The address from which to redeem sGHO shares.
   * @return assets The amount of GHO tokens withdrawn.
   */
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override returns (uint256) {
    uint256 maxShares = maxRedeem(owner);
    if (shares > maxShares) {
      revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
    }

    uint256 assets = previewRedeem(shares);
    _withdraw(_msgSender(), receiver, owner, assets, shares);

    _updateVault(assets, false);

    return assets;
  }

  /**
   * @notice Returns the total amount of GHO tokens managed by the vault.
   * @dev Internal accounting of GHO tokens held by the vault.
   * @return The total GHO assets in the vault.
   */
  function totalAssets() public view override returns (uint256) {
    return internalTotalAssets;
  }

  /**
   * @dev Update the internal total assets of the vault.
   * This function is called when assets are deposited or withdrawn.
   * It also claims the savings from the Yield Maestro if the last update was more than 10 minutes ago.
   * @param assets The amount of assets to update.
   * @param assetIncrease A boolean indicating whether the assets are being increased or decreased.
   */
  function _updateVault(uint256 assets, bool assetIncrease) internal {
    uint256 currentTime = block.timestamp;

    if (currentTime > lastupdate + 600) {
      _claimSavings();
    }

    if (assetIncrease) {
      internalTotalAssets += assets;
    } else {
      internalTotalAssets -= assets;
    }
  }

  /**
   * @dev Internal function that claims accumulated savings from the YieldMaestro contract.
   * It updates `internalTotalAssets` with the claimed amount and resets `lastupdate`.
   */
  function _claimSavings() internal {
    uint256 claimed = IYieldMaestro(YIELD_MAESTRO).claimSavings();
    internalTotalAssets += claimed;
    lastupdate = block.timestamp;
  }

  /**
   * @dev Transfer any excess GHO tokens to the Yield Maestro.
   * @notice This function allows transferring GHO tokens that were sent to this contract
   *         in excess of the `internalTotalAssets` to the `YIELD_MAESTRO` contract.
   *         This ensures donations are not lost and can't be used in a donation attack.
   */
  function takeDonated() external {
    uint256 balance = IERC20(gho).balanceOf(address(this));
    if (balance > internalTotalAssets) {
      IERC20(gho).transfer(YIELD_MAESTRO, balance - internalTotalAssets);
    }
  }
}
