// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.7;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IFlashLoanReceiver} from '../../../flashloan/interfaces/IFlashLoanReceiver.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {Helpers} from '../helpers/Helpers.sol';
import {Errors} from '../helpers/Errors.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {ReserveLogic} from './ReserveLogic.sol';

/**
 * @title SupplyLogic library
 * @author Aave
 * @notice Implements the base logic for supply/withdraw
 */
library SupplyLogic {
  using ReserveLogic for DataTypes.ReserveCache;
  using ReserveLogic for DataTypes.ReserveData;
  using SafeERC20 for IERC20;
  using UserConfiguration for DataTypes.UserConfigurationMap;
  using WadRayMath for uint256;
  using PercentageMath for uint256;

  // See `IPool` for descriptions
  event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);
  event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);
  event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);
  event Supply(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    uint16 indexed referral
  );

  function executeSupply(
    mapping(address => DataTypes.ReserveData) storage reserves,
    DataTypes.UserConfigurationMap storage userConfig,
    mapping(uint256 => address) storage reservesList,
    DataTypes.ExecuteSupplyParams memory vars
  ) internal {
    DataTypes.ReserveData storage reserve = reserves[vars.asset];
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    reserve.updateState(reserveCache);

    ValidationLogic.validateSupply(reserveCache, vars.amount);

    reserve.updateInterestRates(reserveCache, vars.asset, vars.amount, 0);

    IERC20(vars.asset).safeTransferFrom(msg.sender, reserveCache.aTokenAddress, vars.amount);

    IAToken(reserveCache.aTokenAddress).mint(
      vars.onBehalfOf,
      vars.amount,
      reserveCache.nextLiquidityIndex
    );

    if (vars.useAsCollateral) {
      emit ReserveUsedAsCollateralEnabled(vars.asset, vars.onBehalfOf);
    } else {
      if (userConfig.isUsingAsCollateral(reserve.id)) {
        if (userConfig.isBorrowingAny()) {
          ValidationLogic.validateHFAndLtv(
            vars.asset,
            vars.onBehalfOf,
            reserves,
            userConfig,
            reservesList,
            vars.reservesCount,
            vars.oracle
          );
        }
      }
      emit ReserveUsedAsCollateralDisabled(vars.asset, vars.onBehalfOf);
    }

    userConfig.setUsingAsCollateral(reserve.id, vars.useAsCollateral);

    emit Supply(vars.asset, msg.sender, vars.onBehalfOf, vars.amount, vars.referralCode);
  }

  function executeWithdraw(
    mapping(address => DataTypes.ReserveData) storage reserves,
    DataTypes.UserConfigurationMap storage userConfig,
    mapping(uint256 => address) storage reservesList,
    DataTypes.ExecuteWithdrawParams memory vars
  ) internal returns (uint256) {
    DataTypes.ReserveData storage reserve = reserves[vars.asset];
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    reserve.updateState(reserveCache);

    uint256 userBalance = IAToken(reserveCache.aTokenAddress).scaledBalanceOf(msg.sender).rayMul(
      reserveCache.nextLiquidityIndex
    );

    uint256 amountToWithdraw = vars.amount;

    if (vars.amount == type(uint256).max) {
      amountToWithdraw = userBalance;
    }

    ValidationLogic.validateWithdraw(reserveCache, amountToWithdraw, userBalance);

    reserve.updateInterestRates(reserveCache, vars.asset, 0, amountToWithdraw);

    IAToken(reserveCache.aTokenAddress).burn(
      msg.sender,
      vars.to,
      amountToWithdraw,
      reserveCache.nextLiquidityIndex
    );

    if (userConfig.isUsingAsCollateral(reserve.id)) {
      if (userConfig.isBorrowingAny()) {
        ValidationLogic.validateHFAndLtv(
          vars.asset,
          msg.sender,
          reserves,
          userConfig,
          reservesList,
          vars.reservesCount,
          vars.oracle
        );
      }

      if (amountToWithdraw == userBalance) {
        userConfig.setUsingAsCollateral(reserve.id, false);
        emit ReserveUsedAsCollateralDisabled(vars.asset, msg.sender);
      }
    }

    emit Withdraw(vars.asset, msg.sender, vars.to, amountToWithdraw);

    return amountToWithdraw;
  }

  function finalizeTransfer(
    mapping(address => DataTypes.ReserveData) storage reserves,
    mapping(uint256 => address) storage reservesList,
    mapping(address => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.FinalizeTransferParams memory vars
  ) public {
    ValidationLogic.validateTransfer(reserves[vars.asset]);

    uint256 reserveId = reserves[vars.asset].id;

    if (vars.from != vars.to) {
      DataTypes.UserConfigurationMap storage fromConfig = usersConfig[vars.from];

      if (fromConfig.isUsingAsCollateral(reserveId)) {
        if (fromConfig.isBorrowingAny()) {
          ValidationLogic.validateHFAndLtv(
            vars.asset,
            vars.from,
            reserves,
            usersConfig[vars.from],
            reservesList,
            vars.reservesCount,
            vars.oracle
          );
        }
        if (vars.balanceFromBefore - vars.amount == 0) {
          fromConfig.setUsingAsCollateral(reserveId, false);
          emit ReserveUsedAsCollateralDisabled(vars.asset, vars.from);
        }
      }

      if (vars.balanceToBefore == 0 && vars.amount != 0) {
        DataTypes.UserConfigurationMap storage toConfig = usersConfig[vars.to];
        toConfig.setUsingAsCollateral(reserveId, true);
        emit ReserveUsedAsCollateralEnabled(vars.asset, vars.to);
      }
    }
  }

  function setUserUseReserveAsCollateral(
    mapping(address => DataTypes.ReserveData) storage reserves,
    DataTypes.UserConfigurationMap storage userConfig,
    address asset,
    bool useAsCollateral,
    mapping(uint256 => address) storage reservesList,
    uint256 reservesCount,
    address priceOracle
  ) external {
    DataTypes.ReserveData storage reserve = reserves[asset];
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    uint256 userBalance = IERC20(reserveCache.aTokenAddress).balanceOf(msg.sender);

    ValidationLogic.validateSetUseReserveAsCollateral(reserveCache, userBalance);

    userConfig.setUsingAsCollateral(reserve.id, useAsCollateral);

    if (useAsCollateral) {
      emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
    } else {
      ValidationLogic.validateHFAndLtv(
        asset,
        msg.sender,
        reserves,
        userConfig,
        reservesList,
        reservesCount,
        priceOracle
      );

      emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
    }
  }
}
