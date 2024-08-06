{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant bracket" #-}

-- | User-friendly pretty-printing for textual user interfaces (TUI)
module Cardano.CLI.Json.Friendly
  ( -- * Functions in IO

  --
  -- Use them when writing to stdout or to files.
    friendlyTx
  , friendlyTxBody
  , friendlyProposal

    -- * Functions that are not in IO

  --
  -- They are more low-level, but can be used in any context.
  -- The '*Impl' functions give you access to the Aeson representation
  -- of various structures. Then use 'friendlyBS' to format the Aeson
  -- values to a ByteString, in a manner consistent with the IO functions
  -- of this module.
  , friendlyBS
  , friendlyTxImpl
  , friendlyTxBodyImpl
  , friendlyProposalImpl

    -- * Ubiquitous types
  , FriendlyFormat (..)
  , viewOutputFormatToFriendlyFormat
  )
where

import           Cardano.Api as Api
import           Cardano.Api.Byron (KeyWitness (ByronKeyWitness))
import qualified Cardano.Api.Ledger as L
import           Cardano.Api.Shelley (Address (ShelleyAddress), Hash (..),
                   KeyWitness (ShelleyBootstrapWitness, ShelleyKeyWitness), Proposal (..),
                   ShelleyLedgerEra, StakeAddress (..), fromShelleyPaymentCredential,
                   fromShelleyStakeReference, toShelleyStakeCredential)
import qualified Cardano.Api.Shelley as Api

import           Cardano.CLI.Types.Common (ViewOutputFormat (..))
import           Cardano.CLI.Types.MonadWarning (MonadWarning, eitherToWarning, runWarningIO)
import           Cardano.Ledger.Api (AlonzoPlutusPurpose (..), ConwayPlutusPurpose (..), Data,
                   StandardCrypto, unRedeemers)
import qualified Cardano.Ledger.Api as Ledger
import           Cardano.Ledger.Api.Scripts (PlutusPurpose)
import           Cardano.Ledger.Api.Tx (AsIx)
import           Cardano.Prelude (Word32, maybeToEither)

import           Codec.CBOR.Encoding (Encoding)
import           Codec.CBOR.FlatTerm (fromFlatTerm, toFlatTerm)
import           Codec.CBOR.JSON (decodeValue)
import           Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.Aeson.Key as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import           Data.Char (isAscii)
import           Data.Function ((&))
import           Data.Functor ((<&>))
import           Data.List ((!?))
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Ratio (numerator)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import           Data.Yaml (array)
import           Data.Yaml.Pretty (setConfCompare)
import qualified Data.Yaml.Pretty as Yaml
import           GHC.Exts (IsList (..))
import           GHC.Real (denominator)
import           GHC.Unicode (isAlphaNum)

data FriendlyFormat = FriendlyJson | FriendlyYaml

viewOutputFormatToFriendlyFormat :: ViewOutputFormat -> FriendlyFormat
viewOutputFormatToFriendlyFormat = \case
  ViewOutputFormatJson -> FriendlyJson
  ViewOutputFormatYaml -> FriendlyYaml

friendly
  :: (MonadIO m, Aeson.ToJSON a)
  => FriendlyFormat
  -> Maybe (File () Out)
  -> a
  -> m (Either (FileError e) ())
friendly FriendlyJson mOutFile = writeLazyByteStringOutput mOutFile . Aeson.encodePretty' jsonConfig
friendly FriendlyYaml mOutFile = writeByteStringOutput mOutFile . Yaml.encodePretty yamlConfig

friendlyBS
  :: ()
  => Aeson.ToJSON a
  => FriendlyFormat
  -> a
  -> BS.ByteString
friendlyBS FriendlyJson a = BS.concat . LBS.toChunks $ Aeson.encodePretty' jsonConfig a
friendlyBS FriendlyYaml a = Yaml.encodePretty yamlConfig a

jsonConfig :: Aeson.Config
jsonConfig = Aeson.defConfig{Aeson.confCompare = compare}

yamlConfig :: Yaml.Config
yamlConfig = Yaml.defConfig & setConfCompare compare

friendlyTx
  :: MonadIO m
  => FriendlyFormat
  -> Maybe (File () Out)
  -> CardanoEra era
  -> Tx era
  -> m (Either (FileError e) ())
friendlyTx format mOutFile era =
  cardanoEraConstraints
    era
    ( \tx -> do
        pairs <- runWarningIO $ friendlyTxImpl era tx
        friendly format mOutFile $ object pairs
    )

friendlyTxBody
  :: MonadIO m
  => FriendlyFormat
  -> Maybe (File () Out)
  -> CardanoEra era
  -> TxBody era
  -> m (Either (FileError e) ())
friendlyTxBody format mOutFile era =
  cardanoEraConstraints
    era
    ( \tx -> do
        pairs <- runWarningIO $ friendlyTxBodyImpl era tx
        friendly format mOutFile $ object pairs
    )

friendlyProposal
  :: MonadIO m
  => FriendlyFormat
  -> Maybe (File () Out)
  -> ConwayEraOnwards era
  -> Proposal era
  -> m (Either (FileError e) ())
friendlyProposal format mOutFile era =
  conwayEraOnwardsConstraints era $
    friendly format mOutFile . object . friendlyProposalImpl era

friendlyProposalImpl :: ConwayEraOnwards era -> Proposal era -> [Aeson.Pair]
friendlyProposalImpl
  era
  ( Proposal
      ( L.ProposalProcedure
          { L.pProcDeposit
          , L.pProcReturnAddr
          , L.pProcGovAction
          , L.pProcAnchor
          }
        )
    ) =
    conwayEraOnwardsConstraints
      era
      [ "deposit" .= pProcDeposit
      , "return address" .= pProcReturnAddr
      , "governance action" .= pProcGovAction
      , "anchor" .= pProcAnchor
      ]

friendlyTxImpl
  :: MonadWarning m
  => CardanoEra era
  -> Tx era
  -> m [Aeson.Pair]
friendlyTxImpl era (Tx body witnesses) =
  (("witnesses" .= map friendlyKeyWitness witnesses) :) <$> friendlyTxBodyImpl era body

friendlyKeyWitness :: KeyWitness era -> Aeson.Value
friendlyKeyWitness =
  object
    . \case
      ByronKeyWitness txInWitness -> ["Byron witness" .= textShow txInWitness]
      ShelleyBootstrapWitness _era bootstrapWitness ->
        ["bootstrap witness" .= textShow bootstrapWitness]
      ShelleyKeyWitness _era (L.WitVKey key signature) ->
        ["key" .= textShow key, "signature" .= textShow signature]

friendlyTxBodyImpl
  :: MonadWarning m
  => CardanoEra era
  -> TxBody era
  -> m [Aeson.Pair]
friendlyTxBodyImpl
  era
  tb@( TxBody
        -- Enumerating the fields, so that we are warned by GHC when we add a new one
        ( TxBodyContent
            txIns
            txInsCollateral
            txInsReference
            txOuts
            txTotalCollateral
            txReturnCollateral
            txFee
            txValidityLowerBound
            txValidityUpperBound
            txMetadata
            txAuxScripts
            txExtraKeyWits
            _txProtocolParams
            txWithdrawals
            txCertificates
            txUpdateProposal
            txMintValue
            _txScriptValidity
            txProposalProcedures
            txVotingProcedures
            txCurrentTreasuryValue
            txTreasuryDonation
          )
      ) =
    do
      redeemerDetails <- redeemerIfShelleyBased era tb
      return $
        cardanoEraConstraints
          era
          ( redeemerDetails
              ++ [ "auxiliary scripts" .= friendlyAuxScripts txAuxScripts
                 , "certificates" .= forEraInEon era Null (`friendlyCertificates` txCertificates)
                 , "collateral inputs" .= friendlyCollateralInputs txInsCollateral
                 , "era" .= era
                 , "fee" .= friendlyFee txFee
                 , "inputs" .= friendlyInputs txIns
                 , "metadata" .= friendlyMetadata txMetadata
                 , "mint" .= friendlyMintValue txMintValue
                 , "outputs" .= map (friendlyTxOut era) txOuts
                 , "reference inputs" .= friendlyReferenceInputs txInsReference
                 , "total collateral" .= friendlyTotalCollateral txTotalCollateral
                 , "return collateral" .= friendlyReturnCollateral era txReturnCollateral
                 , "required signers (payment key hashes needed for scripts)"
                    .= friendlyExtraKeyWits txExtraKeyWits
                 , "update proposal" .= friendlyUpdateProposal txUpdateProposal
                 , "validity range" .= friendlyValidityRange era (txValidityLowerBound, txValidityUpperBound)
                 , "withdrawals" .= friendlyWithdrawals txWithdrawals
                 ]
              ++ ( monoidForEraInEon @ConwayEraOnwards
                    era
                    ( \cOnwards ->
                        conwayEraOnwardsConstraints cOnwards $
                          case txProposalProcedures of
                            Nothing -> []
                            Just (Featured _ TxProposalProceduresNone) -> []
                            Just (Featured _ pp) -> do
                              let lProposals = toList $ convProposalProcedures pp
                              ["governance actions" .= (friendlyLedgerProposals cOnwards lProposals)]
                    )
                 )
              ++ ( monoidForEraInEon @ConwayEraOnwards
                    era
                    ( \cOnwards ->
                        case txVotingProcedures of
                          Nothing -> []
                          Just (Featured _ TxVotingProceduresNone) -> []
                          Just (Featured _ (TxVotingProcedures votes _witnesses)) ->
                            ["voters" .= friendlyVotingProcedures cOnwards votes]
                    )
                 )
              ++ ( monoidForEraInEon @ConwayEraOnwards
                    era
                    (const ["currentTreasuryValue" .= toJSON (unFeatured <$> txCurrentTreasuryValue)])
                 )
              ++ ( monoidForEraInEon @ConwayEraOnwards
                    era
                    (const ["treasuryDonation" .= toJSON (unFeatured <$> txTreasuryDonation)])
                 )
          )
   where
    friendlyLedgerProposals
      :: ConwayEraOnwards era -> [L.ProposalProcedure (ShelleyLedgerEra era)] -> Aeson.Value
    friendlyLedgerProposals cOnwards proposalProcedures =
      Array $ fromList $ map (friendlyLedgerProposal cOnwards) proposalProcedures

friendlyLedgerProposal
  :: ConwayEraOnwards era -> L.ProposalProcedure (ShelleyLedgerEra era) -> Aeson.Value
friendlyLedgerProposal cOnwards proposalProcedure = object $ friendlyProposalImpl cOnwards (Proposal proposalProcedure)

friendlyVotingProcedures
  :: ConwayEraOnwards era -> L.VotingProcedures (ShelleyLedgerEra era) -> Aeson.Value
friendlyVotingProcedures cOnwards x = conwayEraOnwardsConstraints cOnwards $ toJSON x

redeemerIfShelleyBased :: MonadWarning m => CardanoEra era -> TxBody era -> m [Aeson.Pair]
redeemerIfShelleyBased era tb = monoidForEraInEonA @ShelleyBasedEra era $
  \shEra -> do
    redeemerInfo <- friendlyRedeemers shEra tb
    return ["redeemers" .= redeemerInfo]

data IxType = InputIx | RewardIx

friendlyRedeemers
  :: forall era m. MonadWarning m => ShelleyBasedEra era -> TxBody era -> m Aeson.Value
friendlyRedeemers _ (ShelleyTxBody _ _ _ TxBodyNoScriptData _ _) = return Aeson.Null
friendlyRedeemers sbe txBody@(ShelleyTxBody _ _ _ (TxBodyScriptData _ _ r) _ _) =
  Aeson.Array . Vector.fromList . Map.elems
    <$> Map.traverseWithKey (friendlyRedeemer (getTxInputIx txBody) sbe) (unRedeemers r)
 where
  friendlyRedeemer
    :: (IxType -> Word32 -> Maybe Aeson.Value)
    -> ShelleyBasedEra era
    -> PlutusPurpose AsIx (ShelleyLedgerEra era)
    -> (Data (ShelleyLedgerEra era), a)
    -> m Aeson.Value
  friendlyRedeemer f _ ptr (redeemer, _) = do
    jsonReference <- renderScriptPurpose f sbe ptr
    jsonRedeemer <- encodingToJSON $ L.toCBOR redeemer
    return $ Aeson.Array $ Vector.fromList [jsonReference, jsonRedeemer]

  encodingToJSON :: Encoding -> m Aeson.Value
  encodingToJSON e =
    eitherToWarning Aeson.Null $
      first ("Error decoding redeemer: " ++) $
        fromFlatTerm (decodeValue True) $
          toFlatTerm e

  -- Adapted from cardano-node/cardano-node/src/Cardano/Node/Tracing/Render.hs
  renderScriptPurpose
    :: ()
    => (IxType -> Word32 -> Maybe Aeson.Value)
    -> Api.ShelleyBasedEra era
    -> PlutusPurpose AsIx (Api.ShelleyLedgerEra era)
    -> m Aeson.Value
  renderScriptPurpose f =
    Api.caseShelleyToMaryOrAlonzoEraOnwards
      (const $ const $ return Aeson.Null)
      ( \case
          Api.AlonzoEraOnwardsAlonzo -> renderAlonzoPlutusPurpose f
          Api.AlonzoEraOnwardsBabbage -> renderAlonzoPlutusPurpose f
          Api.AlonzoEraOnwardsConway -> renderConwayPlutusPurpose f
      )

  -- Adapted from cardano-node/cardano-node/src/Cardano/Node/Tracing/Render.hs
  renderAlonzoPlutusPurpose
    :: forall era2
     . Ledger.EraCrypto era2 ~ StandardCrypto
    => (IxType -> Word32 -> Maybe Aeson.Value)
    -> AlonzoPlutusPurpose AsIx era2
    -> m Aeson.Value
  renderAlonzoPlutusPurpose f = \case
    AlonzoSpending (Ledger.AsIx txInIx) -> do
      address <- tryToSolve f InputIx txInIx
      return $ Aeson.object ["spending" .= address]
    AlonzoMinting pid ->
      return $ Aeson.object ["minting" .= Aeson.toJSON pid]
    AlonzoRewarding (Ledger.AsIx rwdAcctIx) -> do
      address <- tryToSolve f RewardIx rwdAcctIx
      return $ Aeson.object ["rewarding" .= address]
    AlonzoCertifying cert ->
      return $ Aeson.object ["certifying" .= Aeson.toJSON cert]

  -- Adapted from cardano-node/cardano-node/src/Cardano/Node/Tracing/Render.hs
  renderConwayPlutusPurpose
    :: forall era2
     . Ledger.EraCrypto era2 ~ StandardCrypto
    => (IxType -> Word32 -> Maybe Aeson.Value)
    -> ConwayPlutusPurpose AsIx era2
    -> m Aeson.Value
  renderConwayPlutusPurpose f = \case
    ConwaySpending (Ledger.AsIx txInIx) -> do
      address <- tryToSolve f InputIx txInIx
      return $ Aeson.object ["spending" .= address]
    ConwayMinting pid ->
      return $ Aeson.object ["minting" .= Aeson.toJSON pid]
    ConwayRewarding (Ledger.AsIx rwdAcctIx) -> do
      address <- tryToSolve f RewardIx rwdAcctIx
      return $ Aeson.object ["rewarding" .= address]
    ConwayCertifying cert ->
      return $ Aeson.object ["certifying" .= Aeson.toJSON cert]
    ConwayVoting voter ->
      return $ Aeson.object ["voting" .= Aeson.toJSON voter]
    ConwayProposing proposal ->
      return $ Aeson.object ["proposing" .= Aeson.toJSON proposal]

  getTxInputIx :: TxBody era -> IxType -> Word32 -> Maybe Aeson.Value
  getTxInputIx (TxBody txBodyContent) InputIx ix = do
    thisTxIn <- txIns txBodyContent !? fromIntegral ix
    return $ toJSON $ fst thisTxIn
  getTxInputIx (TxBody txBodyContent) RewardIx ix = do
    case txWithdrawals txBodyContent of
      TxWithdrawals _ allWithdrawals -> do
        (addr, _, _) <- allWithdrawals !? fromIntegral ix
        return $ toJSON addr
      TxWithdrawalsNone -> Nothing

  tryToSolve
    :: (IxType -> Word32 -> Maybe Aeson.Value)
    -> IxType
    -> Word32
    -> m Aeson.Value
  tryToSolve f ixType ix =
    let ixTypeStr = case ixType of
          InputIx -> "input"
          RewardIx -> "reward"
        msg = "Could not find " <> ixTypeStr <> " with index " <> show ix
     in eitherToWarning (Aeson.Number $ fromIntegral ix) $ maybeToEither msg $ f ixType ix

friendlyTotalCollateral :: TxTotalCollateral era -> Aeson.Value
friendlyTotalCollateral TxTotalCollateralNone = Aeson.Null
friendlyTotalCollateral (TxTotalCollateral _ coll) = toJSON coll

friendlyReturnCollateral
  :: ()
  => CardanoEra era
  -> TxReturnCollateral CtxTx era
  -> Aeson.Value
friendlyReturnCollateral era = \case
  TxReturnCollateralNone -> Aeson.Null
  TxReturnCollateral _ collOut -> friendlyTxOut era collOut

friendlyExtraKeyWits :: TxExtraKeyWitnesses era -> Aeson.Value
friendlyExtraKeyWits = \case
  TxExtraKeyWitnessesNone -> Null
  TxExtraKeyWitnesses _supported paymentKeyHashes -> toJSON paymentKeyHashes

friendlyValidityRange
  :: CardanoEra era
  -> (TxValidityLowerBound era, TxValidityUpperBound era)
  -> Aeson.Value
friendlyValidityRange era = \case
  (lowerBound, upperBound)
    | isLowerBoundSupported || isUpperBoundSupported ->
        object
          [ "lower bound"
              .= case lowerBound of
                TxValidityNoLowerBound -> Null
                TxValidityLowerBound _ s -> toJSON s
          , "upper bound"
              .= case upperBound of
                TxValidityUpperBound _ s -> toJSON s
          ]
    | otherwise -> Null
 where
  isLowerBoundSupported = isJust $ inEonForEraMaybe TxValidityLowerBound era
  isUpperBoundSupported = isJust $ inEonForEraMaybe TxValidityUpperBound era

friendlyWithdrawals :: TxWithdrawals ViewTx era -> Aeson.Value
friendlyWithdrawals TxWithdrawalsNone = Null
friendlyWithdrawals (TxWithdrawals _ withdrawals) =
  array
    [ object $
        "address" .= serialiseAddress addr
          : "amount" .= friendlyLovelace amount
          : friendlyStakeAddress addr
    | (addr, amount, _) <- withdrawals
    ]

friendlyStakeAddress :: StakeAddress -> [Aeson.Pair]
friendlyStakeAddress (StakeAddress net cred) =
  [ "network" .= net
  , friendlyStakeCredential cred
  ]

friendlyTxOut :: CardanoEra era -> TxOut CtxTx era -> Aeson.Value
friendlyTxOut era (TxOut addr amount mdatum script) =
  cardanoEraConstraints era $
    object $
      case addr of
        AddressInEra ByronAddressInAnyEra byronAdr ->
          [ "address era" .= String "Byron"
          , "address" .= serialiseAddress byronAdr
          , "amount" .= friendlyTxOutValue amount
          ]
        AddressInEra (ShelleyAddressInEra _) saddr@(ShelleyAddress net cred stake) ->
          let preAlonzo =
                friendlyPaymentCredential (fromShelleyPaymentCredential cred)
                  : [ "address era" .= Aeson.String "Shelley"
                    , "network" .= net
                    , "address" .= serialiseAddress saddr
                    , "amount" .= friendlyTxOutValue amount
                    , "stake reference" .= friendlyStakeReference (fromShelleyStakeReference stake)
                    ]
              datum = ["datum" .= d | d <- maybeToList $ renderDatum mdatum]
              sinceAlonzo = ["reference script" .= script]
           in preAlonzo ++ datum ++ sinceAlonzo
 where
  renderDatum :: TxOutDatum CtxTx era -> Maybe Aeson.Value
  renderDatum = \case
    TxOutDatumNone -> Nothing
    TxOutDatumHash _ h -> Just $ toJSON h
    TxOutDatumInTx _ sData -> Just $ scriptDataToJson ScriptDataJsonDetailedSchema sData
    TxOutDatumInline _ sData -> Just $ scriptDataToJson ScriptDataJsonDetailedSchema sData

friendlyStakeReference :: StakeAddressReference -> Aeson.Value
friendlyStakeReference = \case
  NoStakeAddress -> Null
  StakeAddressByPointer ptr -> String (textShow ptr)
  StakeAddressByValue cred -> object [friendlyStakeCredential $ toShelleyStakeCredential cred]

friendlyUpdateProposal :: TxUpdateProposal era -> Aeson.Value
friendlyUpdateProposal = \case
  TxUpdateProposalNone -> Null
  TxUpdateProposal _ (UpdateProposal parameterUpdates epoch) ->
    object
      [ "epoch" .= epoch
      , "updates"
          .= [ object
                [ "genesis key hash" .= genesisKeyHash
                , "update" .= friendlyProtocolParametersUpdate parameterUpdate
                ]
             | (genesisKeyHash, parameterUpdate) <- Map.assocs parameterUpdates
             ]
      ]

friendlyProtocolParametersUpdate :: ProtocolParametersUpdate -> Aeson.Value
friendlyProtocolParametersUpdate
  ProtocolParametersUpdate
    { protocolUpdateProtocolVersion
    , protocolUpdateDecentralization
    , protocolUpdateExtraPraosEntropy
    , protocolUpdateMaxBlockHeaderSize
    , protocolUpdateMaxBlockBodySize
    , protocolUpdateMaxTxSize
    , protocolUpdateTxFeeFixed
    , protocolUpdateTxFeePerByte
    , protocolUpdateMinUTxOValue
    , protocolUpdateStakeAddressDeposit
    , protocolUpdateStakePoolDeposit
    , protocolUpdateMinPoolCost
    , protocolUpdatePoolRetireMaxEpoch
    , protocolUpdateStakePoolTargetNum
    , protocolUpdatePoolPledgeInfluence
    , protocolUpdateMonetaryExpansion
    , protocolUpdateTreasuryCut
    , protocolUpdateCollateralPercent
    , protocolUpdateMaxBlockExUnits
    , protocolUpdateMaxCollateralInputs
    , protocolUpdateMaxTxExUnits
    , protocolUpdateMaxValueSize
    , protocolUpdatePrices
    , protocolUpdateUTxOCostPerByte
    } =
    object . catMaybes $
      [ protocolUpdateProtocolVersion <&> \(major, minor) ->
          "protocol version" .= (textShow major <> "." <> textShow minor)
      , protocolUpdateDecentralization
          <&> ("decentralization parameter" .=) . friendlyRational
      , protocolUpdateExtraPraosEntropy
          <&> ("extra entropy" .=) . maybe "reset" toJSON
      , protocolUpdateMaxBlockHeaderSize <&> ("max block header size" .=)
      , protocolUpdateMaxBlockBodySize <&> ("max block body size" .=)
      , protocolUpdateMaxTxSize <&> ("max transaction size" .=)
      , protocolUpdateTxFeeFixed <&> ("transaction fee constant" .=)
      , protocolUpdateTxFeePerByte <&> ("transaction fee linear per byte" .=)
      , protocolUpdateMinUTxOValue <&> ("min UTxO value" .=) . friendlyLovelace
      , protocolUpdateStakeAddressDeposit
          <&> ("key registration deposit" .=) . friendlyLovelace
      , protocolUpdateStakePoolDeposit
          <&> ("pool registration deposit" .=) . friendlyLovelace
      , protocolUpdateMinPoolCost <&> ("min pool cost" .=) . friendlyLovelace
      , protocolUpdatePoolRetireMaxEpoch <&> ("pool retirement epoch boundary" .=)
      , protocolUpdateStakePoolTargetNum <&> ("number of pools" .=)
      , protocolUpdatePoolPledgeInfluence
          <&> ("pool influence" .=) . friendlyRational
      , protocolUpdateMonetaryExpansion
          <&> ("monetary expansion" .=) . friendlyRational
      , protocolUpdateTreasuryCut <&> ("treasury expansion" .=) . friendlyRational
      , protocolUpdateCollateralPercent
          <&> ("collateral inputs share" .=) . (<> "%") . textShow
      , protocolUpdateMaxBlockExUnits <&> ("max block execution units" .=)
      , protocolUpdateMaxCollateralInputs <&> ("max collateral inputs" .=)
      , protocolUpdateMaxTxExUnits <&> ("max transaction execution units" .=)
      , protocolUpdateMaxValueSize <&> ("max value size" .=)
      , protocolUpdatePrices <&> ("execution prices" .=) . friendlyPrices
      , protocolUpdateUTxOCostPerByte
          <&> ("UTxO storage cost per byte" .=) . friendlyLovelace
      ]

friendlyPrices :: ExecutionUnitPrices -> Aeson.Value
friendlyPrices ExecutionUnitPrices{priceExecutionMemory, priceExecutionSteps} =
  object
    [ "memory" .= friendlyRational priceExecutionMemory
    , "steps" .= friendlyRational priceExecutionSteps
    ]

friendlyCertificates :: ShelleyBasedEra era -> TxCertificates ViewTx era -> Aeson.Value
friendlyCertificates sbe = \case
  TxCertificatesNone -> Null
  TxCertificates _ cs _ -> array $ map (friendlyCertificate sbe) cs

friendlyCertificate :: ShelleyBasedEra era -> Certificate era -> Aeson.Value
friendlyCertificate sbe =
  shelleyBasedEraConstraints sbe $
    object . (: []) . renderCertificate sbe

renderCertificate :: ShelleyBasedEra era -> Certificate era -> (Aeson.Key, Aeson.Value)
renderCertificate sbe = \case
  ShelleyRelatedCertificate _ c ->
    shelleyBasedEraConstraints sbe $
      case c of
        L.ShelleyTxCertDelegCert (L.ShelleyRegCert cred) ->
          "stake address registration" .= cred
        L.ShelleyTxCertDelegCert (L.ShelleyUnRegCert cred) ->
          "stake address deregistration" .= cred
        L.ShelleyTxCertDelegCert (L.ShelleyDelegCert cred poolId) ->
          "stake address delegation"
            .= object
              [ "credential" .= cred
              , "pool" .= poolId
              ]
        L.ShelleyTxCertPool (L.RetirePool poolId retirementEpoch) ->
          "stake pool retirement"
            .= object
              [ "pool" .= StakePoolKeyHash poolId
              , "epoch" .= retirementEpoch
              ]
        L.ShelleyTxCertPool (L.RegPool poolParams) ->
          "stake pool registration" .= poolParams
        L.ShelleyTxCertGenesisDeleg (L.GenesisDelegCert genesisKeyHash delegateKeyHash vrfKeyHash) ->
          "genesis key delegation"
            .= object
              [ "genesis key hash" .= genesisKeyHash
              , "delegate key hash" .= delegateKeyHash
              , "VRF key hash" .= vrfKeyHash
              ]
        L.ShelleyTxCertMir (L.MIRCert pot target) ->
          "MIR"
            .= object
              [ "pot" .= friendlyMirPot pot
              , friendlyMirTarget sbe target
              ]
  ConwayCertificate w cert ->
    conwayEraOnwardsConstraints w $
      case cert of
        L.RegDRepTxCert credential coin mAnchor ->
          "Drep registration certificate"
            .= object
              [ "deposit" .= coin
              , "certificate" .= conwayToObject w credential
              , "anchor" .= mAnchor
              ]
        L.UnRegDRepTxCert credential coin ->
          "Drep unregistration certificate"
            .= object
              [ "refund" .= coin
              , "certificate" .= conwayToObject w credential
              ]
        L.AuthCommitteeHotKeyTxCert coldCred hotCred
          | L.ScriptHashObj sh <- coldCred ->
              "Cold committee authorization"
                .= object
                  ["script hash" .= sh]
          | L.ScriptHashObj sh <- hotCred ->
              "Hot committee authorization"
                .= object
                  ["script hash" .= sh]
          | L.KeyHashObj ck@L.KeyHash{} <- coldCred
          , L.KeyHashObj hk@L.KeyHash{} <- hotCred ->
              "Constitutional committee member hot key registration"
                .= object
                  [ "cold key hash" .= ck
                  , "hot key hash" .= hk
                  ]
        L.ResignCommitteeColdTxCert cred anchor -> case cred of
          L.ScriptHashObj sh ->
            "Cold committee resignation"
              .= object
                [ "script hash" .= sh
                , "anchor" .= anchor
                ]
          L.KeyHashObj ck@L.KeyHash{} ->
            "Constitutional committee cold key resignation"
              .= object
                [ "cold key hash" .= ck
                ]
        L.RegTxCert stakeCredential ->
          "Stake address registration"
            .= object
              [ "stake credential" .= stakeCredential
              ]
        L.UnRegTxCert stakeCredential ->
          "Stake address deregistration"
            .= object
              [ "stake credential" .= stakeCredential
              ]
        L.RegDepositTxCert stakeCredential deposit ->
          "Stake address registration"
            .= object
              [ "stake credential" .= stakeCredential
              , "deposit" .= deposit
              ]
        L.UnRegDepositTxCert stakeCredential refund ->
          "Stake address deregistration"
            .= object
              [ "stake credential" .= stakeCredential
              , "refund" .= refund
              ]
        L.DelegTxCert stakeCredential delegatee ->
          "Stake address delegation"
            .= object
              [ "stake credential" .= stakeCredential
              , "delegatee" .= delegateeJson sbe delegatee
              ]
        L.RegDepositDelegTxCert stakeCredential delegatee deposit ->
          "Stake address registration and delegation"
            .= object
              [ "stake credential" .= stakeCredential
              , "delegatee" .= delegateeJson sbe delegatee
              , "deposit" .= deposit
              ]
        L.RegPoolTxCert poolParams ->
          "Pool registration"
            .= object
              [ "pool params" .= poolParams
              ]
        L.RetirePoolTxCert kh@L.KeyHash{} epoch ->
          "Pool retirement"
            .= object
              [ "stake pool key hash" .= kh
              , "epoch" .= epoch
              ]
        L.UpdateDRepTxCert drepCredential mbAnchor ->
          "Drep certificate update"
            .= object
              [ "Drep credential" .= drepCredential
              , "anchor " .= mbAnchor
              ]
 where
  conwayToObject
    :: ()
    => ConwayEraOnwards era
    -> L.Credential 'L.DRepRole (L.EraCrypto (ShelleyLedgerEra era))
    -> Aeson.Value
  conwayToObject w' =
    conwayEraOnwardsConstraints w' $
      object . \case
        L.ScriptHashObj sHash -> ["scriptHash" .= sHash]
        L.KeyHashObj keyHash -> ["keyHash" .= keyHash]

  delegateeJson
    :: L.EraCrypto (ShelleyLedgerEra era) ~ L.StandardCrypto
    => ShelleyBasedEra era
    -> L.Delegatee (L.EraCrypto (ShelleyLedgerEra era))
    -> Aeson.Value
  delegateeJson _ =
    object . \case
      L.DelegStake hk@L.KeyHash{} ->
        [ "delegatee type" .= String "stake"
        , "key hash" .= hk
        ]
      L.DelegVote drep -> do
        ["delegatee type" .= String "vote", "DRep" .= drep]
      L.DelegStakeVote kh drep ->
        [ "delegatee type" .= String "stake vote"
        , "key hash" .= kh
        , "DRep" .= drep
        ]

friendlyMirTarget
  :: ShelleyBasedEra era -> L.MIRTarget (L.EraCrypto (ShelleyLedgerEra era)) -> Aeson.Pair
friendlyMirTarget sbe = \case
  L.StakeAddressesMIR addresses ->
    "target stake addresses"
      .= [ object
            [ friendlyStakeCredential credential
            , "amount" .= friendlyLovelace (L.Coin 0 `L.addDeltaCoin` lovelace)
            ]
         | (credential, lovelace) <- shelleyBasedEraConstraints sbe $ toList addresses
         ]
  L.SendToOppositePotMIR amount -> "MIR amount" .= friendlyLovelace amount

friendlyStakeCredential
  :: L.Credential L.Staking L.StandardCrypto -> Aeson.Pair
friendlyStakeCredential = \case
  L.KeyHashObj keyHash ->
    "stake credential key hash" .= keyHash
  L.ScriptHashObj scriptHash ->
    "stake credential script hash" .= scriptHash

friendlyPaymentCredential :: PaymentCredential -> Aeson.Pair
friendlyPaymentCredential = \case
  PaymentCredentialByKey keyHash ->
    "payment credential key hash" .= keyHash
  PaymentCredentialByScript scriptHash ->
    "payment credential script hash" .= scriptHash

friendlyMirPot :: L.MIRPot -> Aeson.Value
friendlyMirPot = \case
  L.ReservesMIR -> "reserves"
  L.TreasuryMIR -> "treasury"

friendlyRational :: Rational -> Aeson.Value
friendlyRational r =
  String $
    case d of
      1 -> textShow n
      _ -> textShow n <> "/" <> textShow d
 where
  n = numerator r
  d = denominator r

friendlyFee :: TxFee era -> Aeson.Value
friendlyFee = \case
  TxFeeExplicit _ fee -> friendlyLovelace fee

friendlyLovelace :: Lovelace -> Aeson.Value
friendlyLovelace value = String $ docToText (pretty value)

friendlyMintValue :: TxMintValue ViewTx era -> Aeson.Value
friendlyMintValue = \case
  TxMintNone -> Null
  TxMintValue sbe v _ -> friendlyValue (maryEraOnwardsToShelleyBasedEra sbe) v

friendlyTxOutValue :: TxOutValue era -> Aeson.Value
friendlyTxOutValue = \case
  TxOutValueByron lovelace -> friendlyLovelace lovelace
  TxOutValueShelleyBased sbe v -> friendlyLedgerValue sbe v

friendlyLedgerValue
  :: ()
  => ShelleyBasedEra era
  -> L.Value (ShelleyLedgerEra era)
  -> Aeson.Value
friendlyLedgerValue sbe v = friendlyValue sbe $ Api.fromLedgerValue sbe v

friendlyValue
  :: ()
  => ShelleyBasedEra era
  -> Api.Value
  -> Aeson.Value
friendlyValue _ v =
  object
    [ case bundle of
        ValueNestedBundleAda q -> "lovelace" .= q
        ValueNestedBundle policy assets ->
          Aeson.fromText (friendlyPolicyId policy) .= friendlyAssets assets
    | bundle <- bundles
    ]
 where
  ValueNestedRep bundles = valueToNestedRep v

  friendlyPolicyId = ("policy " <>) . serialiseToRawBytesHexText

  friendlyAssets = Map.mapKeys friendlyAssetName

  friendlyAssetName = \case
    "" -> "default asset"
    name@(AssetName nameBS) ->
      "asset " <> serialiseToRawBytesHexText name <> nameAsciiSuffix
     where
      nameAsciiSuffix
        | nameIsAscii = " (" <> nameAscii <> ")"
        | otherwise = ""
      nameIsAscii = BSC.all (\c -> isAscii c && isAlphaNum c) nameBS
      nameAscii = Text.pack $ BSC.unpack nameBS

friendlyMetadata :: TxMetadataInEra era -> Aeson.Value
friendlyMetadata = \case
  TxMetadataNone -> Null
  TxMetadataInEra _ (TxMetadata m) -> toJSON $ friendlyMetadataValue <$> m

friendlyMetadataValue :: TxMetadataValue -> Aeson.Value
friendlyMetadataValue = \case
  TxMetaNumber int -> toJSON int
  TxMetaBytes bytes -> String $ textShow bytes
  TxMetaList lst -> array $ map friendlyMetadataValue lst
  TxMetaMap m ->
    array
      [array [friendlyMetadataValue k, friendlyMetadataValue v] | (k, v) <- m]
  TxMetaText text -> toJSON text

friendlyAuxScripts :: TxAuxScripts era -> Aeson.Value
friendlyAuxScripts = \case
  TxAuxScriptsNone -> Null
  TxAuxScripts _ scripts -> String $ textShow scripts

friendlyReferenceInputs :: TxInsReference era -> Aeson.Value
friendlyReferenceInputs TxInsReferenceNone = Null
friendlyReferenceInputs (TxInsReference _ txins) = toJSON txins

friendlyInputs :: [(TxIn, build)] -> Aeson.Value
friendlyInputs = toJSON . map fst

friendlyCollateralInputs :: TxInsCollateral era -> Aeson.Value
friendlyCollateralInputs = \case
  TxInsCollateralNone -> Null
  TxInsCollateral _ txins -> toJSON txins
