// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/LiquidationFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/facets/YieldStrategyFacet.sol";
import "../contracts/Diamond.sol";
import {VaultConfiguration, RepayRequest, LiquidationRequest} from "../contracts/models/Protocol.sol";

import {Test} from "forge-std/Test.sol";

contract Base is Test, IDiamondCut {
    //contract types of facets to be deployed
    Diamond diamond;
    DiamondCutFacet dCutFacet;
    DiamondLoupeFacet dLoupe;
    OwnershipFacet ownerF;
    ProtocolFacet protocolF;
    PositionManagerFacet positionManagerF;
    VaultManagerFacet vaultManagerF;
    PriceOracleFacet priceOracleF;
    LiquidationFacet liquidationF;
    YieldStrategyFacet yieldStrategyF;

    // Test tokens
    ERC20Mock token1;
    ERC20Mock token2;
    ERC20Mock token3;
    ERC20Mock token4;
    address pricefeed1;
    address pricefeed2;
    address pricefeed3;
    address pricefeed4;

    address vault;

    // Test addresses
    address user1 = mkaddr("user1");
    address user2 = mkaddr("user2");
    address nonAdmin = mkaddr("nonAdmin");

    uint16 baseTokenLTV = 8000;
    uint256 internal constant REQUEST_SIGNER_PRIVATE_KEY = 0xA11CE;
    address internal requestSignerAddress = vm.addr(REQUEST_SIGNER_PRIVATE_KEY);
    uint256 internal repayRequestNonce;
    string internal constant REPAY_ACTION = "REPAY_LOAN";
    string internal constant LIQUIDATE_ACTION = "LIQUIDATE_LOAN";

    VaultConfiguration defaultConfig = VaultConfiguration({
        totalDeposits: 0,
        totalBorrows: 0,
        baseRate: 2000,
        slopeRate: 2500,
        reserveFactor: 2000,
        optimalUtilization: 7500,
        liquidationBonus: 1000,
        lastUpdated: block.timestamp
    });

    function setUp() public virtual {
        //deploy facets
        dCutFacet = new DiamondCutFacet();
        diamond = new Diamond(address(this), address(dCutFacet));
        dLoupe = new DiamondLoupeFacet();
        ownerF = new OwnershipFacet();
        protocolF = new ProtocolFacet();
        positionManagerF = new PositionManagerFacet();
        vaultManagerF = new VaultManagerFacet();
        priceOracleF = new PriceOracleFacet();
        liquidationF = new LiquidationFacet();
        yieldStrategyF = new YieldStrategyFacet();

        //upgrade diamond with facets
        //build cut struct
        FacetCut[] memory cut = new FacetCut[](8);

        cut[0] =
        (FacetCut({
                facetAddress: address(dLoupe),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("DiamondLoupeFacet")
            }));

        cut[1] =
        (FacetCut({
                facetAddress: address(ownerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("OwnershipFacet")
            }));

        cut[2] =
        (FacetCut({
                facetAddress: address(protocolF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("ProtocolFacet")
            }));

        cut[3] =
        (FacetCut({
                facetAddress: address(positionManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PositionManagerFacet")
            }));

        cut[4] =
        (FacetCut({
                facetAddress: address(vaultManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("VaultManagerFacet")
            }));

        cut[5] =
        (FacetCut({
                facetAddress: address(priceOracleF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PriceOracleFacet")
            }));

        cut[6] =
        (FacetCut({
                facetAddress: address(liquidationF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("LiquidationFacet")
            }));

        cut[7] =
        (FacetCut({
                facetAddress: address(yieldStrategyF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("YieldStrategyFacet")
            }));

        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));
        yieldStrategyF = YieldStrategyFacet(address(diamond));

        //upgrade diamond
        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");

        //call a function
        DiamondLoupeFacet(address(diamond)).facetAddresses();

        // Deploy test tokens
        (address _token1, address _pricefeed1) = deployERC20ContractAndAddPriceFeed("token1", 18, 1500);
        (address _token2, address _pricefeed2) = deployERC20ContractAndAddPriceFeed("token2", 18, 300);
        (address _token3, address _pricefeed3) = deployERC20ContractAndAddPriceFeed("token3", 6, 1);

        token1 = ERC20Mock(_token1);
        token2 = ERC20Mock(_token2);
        token3 = ERC20Mock(_token3);

        pricefeed1 = _pricefeed1;
        pricefeed2 = _pricefeed2;
        pricefeed3 = _pricefeed3;

        // Setup initial collateral tokens
        whitelistUserAddresses();
        _setupInitialCollateralTokens();
        protocolF.setInterestRate(2000, 500);
        positionManagerF.setRequestSigner(requestSignerAddress);
    }

    function _setupInitialCollateralTokens() internal virtual {
        protocolF.addCollateralToken(address(token1), pricefeed1, baseTokenLTV);
        protocolF.addCollateralToken(address(token2), pricefeed2, baseTokenLTV);
        protocolF.addCollateralToken(address(1), pricefeed1, baseTokenLTV); // Native token
    }

    function deployERC20ContractAndAddPriceFeed(string memory _name, uint8 _decimals, int256 _initialAnswer)
        internal
        returns (address, address)
    {
        ERC20Mock _erc20 = new ERC20Mock(_decimals);
        MockV3Aggregator priceFeed = new MockV3Aggregator(8, _initialAnswer * 1e8);
        vm.label(address(priceFeed), "Price Feed");
        vm.label(address(_erc20), _name);
        return (address(_erc20), address(priceFeed));
    }

    function depositCollateralFor(address _user, address _token, uint256 _amount)
        internal
        virtual
        returns (uint256 positionId)
    {
        if (_token == address(1)) {
            vm.deal(_user, _amount);
        } else {
            token1.mint(_user, _amount);
        }
        vm.startPrank(_user);
        if (_token == address(1)) {
            protocolF.depositCollateral{value: _amount}(_token, _amount);
        } else {
            ERC20Mock(_token).approve(address(diamond), _amount);
            protocolF.depositCollateral(_token, _amount);
        }
        vm.stopPrank();
        positionId = positionManagerF.getPositionIdForUser(_user);
    }

    function mintTokenTo(address _token, address _user, uint256 _amount) internal {
        ERC20Mock token = ERC20Mock(_token);
        token.mint(_user, _amount);
    }

    function executeRepayLoan(uint256 _loanId, uint256 _amount) internal virtual returns (uint256) {
        (RepayRequest memory request, bytes memory signature) = buildRepayRequest(_loanId, _amount);
        return protocolF.repayLoan(request, signature);
    }

    // function executeLiquidateLoan(uint256 _loanId, uint256 _amount, address collateralToken) internal virtual {
    //     (LiquidationRequest memory request, bytes memory signature) =
    //         buildLiquidationRequest(_loanId, _amount, collateralToken);
    //     return liquidationF.liquidateLoan(request, signature);
    // }

    function buildRepayRequest(uint256 _loanId, uint256 _amount)
        internal
        returns (RepayRequest memory request, bytes memory signature)
    {
        request = createRepayRequest(_loanId, _amount);
        signature = _signRepayRequest(request);
    }

    function buildLiquidationRequest(uint256 _loanId, uint256 _amount, address collateralToken)
        internal
        returns (LiquidationRequest memory request, bytes memory signature)
    {
        request = createLiquidationRequest(_loanId, _amount, collateralToken);
        signature = _signLiquidationRequest(request);
    }

    function createRepayRequest(uint256 _loanId, uint256 _amount)
        internal
        virtual
        returns (RepayRequest memory request)
    {
        request = RepayRequest({
            action: REPAY_ACTION,
            loanId: _loanId,
            amount: _amount,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: ++repayRequestNonce,
            contractAddress: address(protocolF),
            walletAddress: msg.sender
        });
    }

    function createLiquidationRequest(uint256 _loanId, uint256 _amount, address collateralToken)
        internal
        virtual
        returns (LiquidationRequest memory request)
    {
        request = LiquidationRequest({
            action: LIQUIDATE_ACTION,
            loanId: _loanId,
            amount: _amount,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: ++repayRequestNonce,
            contractAddress: address(protocolF),
            collateralToken: collateralToken,
            walletAddress: msg.sender
        });
    }

    function _signRepayRequest(RepayRequest memory request) internal pure returns (bytes memory signature) {
        signature = signRepayRequestWithKey(request, REQUEST_SIGNER_PRIVATE_KEY);
    }

    function _signLiquidationRequest(LiquidationRequest memory request) internal pure returns (bytes memory signature) {
        bytes32 digest = _liquidationRequestDigest(request);
        signature = signDigestWithKey(digest, REQUEST_SIGNER_PRIVATE_KEY);
    }

    function signRepayRequestWithKey(RepayRequest memory request, uint256 privateKey)
        internal
        pure
        returns (bytes memory signature)
    {
        bytes32 digest = _repayRequestDigest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function signDigestWithKey(bytes32 digest, uint256 privateKey) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _repayRequestDigest(RepayRequest memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        request.action,
                        request.loanId,
                        request.amount,
                        request.sourceChainId,
                        request.targetChainId,
                        request.nonce,
                        request.contractAddress
                    )
                )
            )
        );
    }

    function _liquidationRequestDigest(LiquidationRequest memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        request.action,
                        request.loanId,
                        request.amount,
                        request.sourceChainId,
                        request.targetChainId,
                        request.nonce,
                        request.contractAddress,
                        request.collateralToken
                    )
                )
            )
        );
    }

    function createVaultAndFund(uint256 _amount) internal {
        (address _token4, address _pricefeed4) = deployERC20ContractAndAddPriceFeed("SupToken", 6, 250);
        token4 = ERC20Mock(_token4);
        pricefeed4 = _pricefeed4;

        // address _vault =
        vault = vaultManagerF.deployVault(address(token4), pricefeed4, "xSToken", "xSTK", defaultConfig);

        token4.mint(address(this), _amount);
        token4.approve(address(vaultManagerF), _amount);

        vaultManagerF.deposit(_token4, _amount);
    }

    function whitelistUserAddresses() internal {
        positionManagerF.whitelistAddress(address(this));
        positionManagerF.whitelistAddress(user1);
        positionManagerF.whitelistAddress(user2);
        positionManagerF.whitelistAddress(nonAdmin);
    }

    function mkaddr(string memory name) public returns (address) {
        address addr = address(uint160(uint256(keccak256(abi.encodePacked(name)))));
        vm.label(addr, name);
        return addr;
    }

    function generateSelectors(string memory _facetName) internal returns (bytes4[] memory selectors) {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "scripts/genSelectors.js";
        cmd[2] = _facetName;
        bytes memory res = vm.ffi(cmd);
        selectors = abi.decode(res, (bytes4[]));
    }

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {}
}
