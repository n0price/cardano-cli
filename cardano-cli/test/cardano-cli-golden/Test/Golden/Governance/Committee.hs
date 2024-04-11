{-# LANGUAGE TypeApplications #-}

{- HLINT ignore "Use camelCase" -}

module Test.Golden.Governance.Committee where

import           Control.Monad (forM_, void)

import           Test.Cardano.CLI.Util

import           Hedgehog (Property)
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H
import qualified Hedgehog.Extras.Test.Golden as H

hprop_golden_governanceCommitteeKeyGenCold :: Property
hprop_golden_governanceCommitteeKeyGenCold =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    verificationKeyFile <- noteTempFile tempDir "key-gen.vkey"
    signingKeyFile <- noteTempFile tempDir "key-gen.skey"

    void $ execCardanoCLI
      [ "conway", "governance", "committee", "key-gen-cold"
      , "--verification-key-file", verificationKeyFile
      , "--signing-key-file", signingKeyFile
      ]

    H.assertFileOccurences 1 "ConstitutionalCommitteeColdVerificationKey_ed25519" verificationKeyFile
    H.assertFileOccurences 1 "ConstitutionalCommitteeColdSigningKey_ed25519" signingKeyFile

    H.assertEndsWithSingleNewline verificationKeyFile
    H.assertEndsWithSingleNewline signingKeyFile

hprop_golden_governanceCommitteeKeyGenHot :: Property
hprop_golden_governanceCommitteeKeyGenHot =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    verificationKeyFile <- noteTempFile tempDir "key-gen.vkey"
    signingKeyFile <- noteTempFile tempDir "key-gen.skey"

    void $ execCardanoCLI
      [  "conway", "governance", "committee", "key-gen-hot"
      , "--verification-key-file", verificationKeyFile
      , "--signing-key-file", signingKeyFile
      ]

    H.assertFileOccurences 1 "ConstitutionalCommitteeHotVerificationKey_ed25519" verificationKeyFile
    H.assertFileOccurences 1 "ConstitutionalCommitteeHotSigningKey_ed25519" signingKeyFile

    H.assertFileOccurences 1 "Constitutional Committee Hot Verification Key" verificationKeyFile
    H.assertFileOccurences 1 "Constitutional Committee Hot Signing Key" signingKeyFile

    H.assertEndsWithSingleNewline verificationKeyFile
    H.assertEndsWithSingleNewline signingKeyFile

hprop_golden_governanceCommitteeCreateHotKeyAuthorizationCertificate :: Property
hprop_golden_governanceCommitteeCreateHotKeyAuthorizationCertificate =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    ccColdVKey <- noteTempFile tempDir "cc-cold.vkey"
    ccColdSKey <- noteTempFile tempDir "cc-cold.skey"
    ccHotVKey <- noteTempFile tempDir "cc-hot.vkey"
    ccHotSKey <- noteTempFile tempDir "cc-hot.skey"

    certFile <- noteTempFile tempDir "hot-auth.cert"

    void $ execCardanoCLI
      [ "conway", "governance", "committee", "key-gen-cold"
      , "--verification-key-file", ccColdVKey
      , "--signing-key-file", ccColdSKey
      ]

    void $ execCardanoCLI
      [ "conway", "governance", "committee", "key-gen-hot"
      , "--verification-key-file", ccHotVKey
      , "--signing-key-file", ccHotSKey
      ]

    void $ execCardanoCLI
      [ "conway", "governance", "committee", "create-hot-key-authorization-certificate"
      , "--cold-verification-key-file", ccColdVKey
      , "--hot-key-file", ccHotVKey
      , "--out-file", certFile
      ]

    H.assertFileOccurences 1 "CertificateConway" certFile
    H.assertFileOccurences 1 "Constitutional Committee Hot Key Registration Certificate" certFile

hprop_golden_governanceCommitteeCreateColdKeyResignationCertificate :: Property
hprop_golden_governanceCommitteeCreateColdKeyResignationCertificate =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    ccColdVKey <- noteTempFile tempDir "cold.vkey"
    ccColdSKey <- noteTempFile tempDir "cold.skey"

    certFile <- noteTempFile tempDir "hot-auth.cert"

    void $ execCardanoCLI
      [ "conway", "governance", "committee", "key-gen-cold"
      , "--verification-key-file", ccColdVKey
      , "--signing-key-file", ccColdSKey
      ]

    void $ execCardanoCLI
      [  "conway", "governance", "committee", "create-cold-key-resignation-certificate"
      , "--cold-verification-key-file", ccColdVKey
      , "--out-file", certFile
      ]

    H.assertFileOccurences 1 "CertificateConway" certFile
    H.assertFileOccurences 1 "Constitutional Committee Cold Key Resignation Certificate" certFile

hprop_golden_governanceUpdateCommittee :: Property
hprop_golden_governanceUpdateCommittee =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    stakeVkey <- noteInputFile "test/cardano-cli-golden/files/input/governance/stake-address.vkey"
    ccProposal <- noteInputFile "test/cardano-cli-golden/files/input/governance/committee/cc-proposal.txt"
    coldCCVkey1 <- noteInputFile "test/cardano-cli-golden/files/input/governance/committee/cc-cold1.vkey"
    coldCCVkey2 <- noteInputFile "test/cardano-cli-golden/files/input/governance/committee/cc-cold2.vkey"

    outFile <- H.noteTempFile tempDir "answer-file.json"

    proposalHash <- execCardanoCLI
      [ "conway", "governance", "hash", "anchor-data"
      , "--file-text", ccProposal ]

    H.note_ proposalHash
    H.note_ $ show $ length proposalHash

    goldenAnswerFile <- H.note "test/cardano-cli-golden/files/golden/governance/committee/update-committee-answer.json"

    void $ execCardanoCLI
      [ "conway", "governance", "action", "update-committee"
      , "--testnet", "--governance-action-deposit", "0"
      , "--deposit-return-stake-verification-key-file", stakeVkey
      , "--anchor-url", "http://dummy"
      , "--anchor-data-hash", proposalHash
      , "--add-cc-cold-verification-key-file", coldCCVkey1
      , "--epoch", "202"
      , "--add-cc-cold-verification-key-file", coldCCVkey2
      , "--epoch", "252"
      , "--threshold", "51/100"
      , "--out-file", outFile
      ]

    H.diffFileVsGoldenFile outFile goldenAnswerFile

-- | Execute me with:
-- @cabal test cardano-cli-golden --test-options '-p "/golden governance committee cold extended key signing/"'@
hprop_golden_governance_committee_cold_extended_key_signing :: Property
hprop_golden_governance_committee_cold_extended_key_signing =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    skeyFile <- noteInputFile "test/cardano-cli-golden/files/input/governance/committee/cc.extended.cold.skey"
    txBody <- noteInputFile "test/cardano-cli-golden/files/input/governance/drep/extended-key-signing/tx.body"

    outGold <- H.note "test/cardano-cli-golden/files/golden/governance/committee/tx.cold.extended.signed"
    outFile <- H.noteTempFile tempDir "outFile"

    H.noteM_ $ execCardanoCLI
      [  "conway", "transaction", "sign"
      , "--tx-body-file", txBody
      , "--signing-key-file", skeyFile
      , "--out-file", outFile
      ]

    H.diffFileVsGoldenFile outFile outGold

-- | Execute me with:
-- @cabal test cardano-cli-golden --test-options '-p "/golden governance committee hot extended key signing/"'@
hprop_golden_governance_committee_hot_extended_key_signing :: Property
hprop_golden_governance_committee_hot_extended_key_signing =
  propertyOnce . H.moduleWorkspace "tmp" $ \tempDir -> do
    skeyFile <- noteInputFile "test/cardano-cli-golden/files/input/governance/committee/cc.extended.hot.skey"
    txBody <- noteInputFile "test/cardano-cli-golden/files/input/governance/drep/extended-key-signing/tx.body"

    outGold <- H.note "test/cardano-cli-golden/files/golden/governance/committee/tx.hot.extended.signed"
    outFile <- H.noteTempFile tempDir "outFile"

    H.noteM_ $ execCardanoCLI
      [  "conway", "transaction", "sign"
      , "--tx-body-file", txBody
      , "--signing-key-file", skeyFile
      , "--out-file", outFile
      ]

    H.diffFileVsGoldenFile outFile outGold

-- | Execute me with:
-- @cabal test cardano-cli-golden --test-options '-p "/golden verification key committee/"'@
hprop_golden_verification_key_committee :: Property
hprop_golden_verification_key_committee = do
  let values = [ ( "test/cardano-cli-golden/files/input/governance/committee/cc.extended.hot.skey"
                 , "test/cardano-cli-golden/files/golden/governance/committee/cc.extended.hot.vkey"
                 )
                 ,
                 ( "test/cardano-cli-golden/files/input/governance/committee/cc.extended.cold.skey"
                 , "test/cardano-cli-golden/files/golden/governance/committee/cc.extended.cold.vkey"
                 )
               ]

  propertyOnce $ forM_ values $ \(skeyFile, vkeyGolden) ->
    H.moduleWorkspace "tmp" $ \tempDir -> do
      vkeyFileOut <- noteTempFile tempDir "cc.extended.vkey"

      H.noteM_ $ execCardanoCLI
        [  "conway", "key", "verification-key"
        , "--signing-key-file", skeyFile
        , "--verification-key-file", vkeyFileOut
        ]

      H.diffFileVsGoldenFile vkeyFileOut vkeyGolden
