{--
   Copyright 2021 ₳DAO

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
--}

{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE LambdaCase          #-}

module YoctoDao.Core where

import           Prelude                (String, show, Show)
import           Control.Monad          hiding (fmap)
import           PlutusTx.Maybe
import qualified Data.Map               as Map
import           Data.Text              (Text)
import           Data.Void              (Void)
import           Plutus.Contract        as Contract
import qualified PlutusTx
import           PlutusTx.IsData
import           PlutusTx.Prelude       hiding (Semigroup(..), unless)
import           Ledger                 hiding (singleton)
import           Ledger.Ada             as Ada
import           Ledger.Constraints     as Constraints
import           Ledger.Index           as Index
import qualified Ledger.Typed.Scripts   as Scripts
import qualified Ledger.Contexts                   as Validation
import           Ledger.Value           as Value
import           Playground.Contract    (printJson, printSchemas, ensureKnownCurrencies, stage, ToSchema, NonEmpty(..) )
import           Playground.TH          (mkKnownCurrencies, mkSchemaDefinitions, ensureKnownCurrencies)
import           Playground.Types       (KnownCurrency (..))
import           Prelude                (Semigroup (..))
import           Text.Printf            (printf)
import           GHC.Generics         (Generic)
import           Data.String          (IsString (..))
import           Data.Aeson           (ToJSON, FromJSON)
import           Playground.Contract

data Proposal = Proposal
    { proposalStart :: !POSIXTime
    , scriptUpdate  :: !Bool
    , scriptAddr    :: Address
    , spend         :: !Bool
    , spendValue    :: Value
    , spendAddr     :: Address
    , minting       :: !Bool
    , minted        :: Integer
    , yes           :: !Integer
    , no            :: !Integer
    } deriving (Show, Generic, FromJSON, ToJSON)

PlutusTx.makeLift ''Proposal
PlutusTx.unstableMakeIsData ''Proposal

data Ownership = Ownership
    { owner        :: !PubKeyHash
    , nftSlot      :: POSIXTime
    , lastTransfer :: POSIXTime
    } deriving (Show, Generic, FromJSON, ToJSON)

PlutusTx.makeLift ''Ownership
PlutusTx.unstableMakeIsData ''Ownership

data TokenTrace = TokenTrace
    { tMinted             :: !Integer
    , treasuryValue       :: !Integer
    } deriving (Show, Generic, FromJSON, ToJSON)

PlutusTx.makeLift ''TokenTrace
PlutusTx.unstableMakeIsData ''TokenTrace

data IdMaker = IdMaker AssetClass
    deriving (Show, Generic, FromJSON, ToJSON)

PlutusTx.makeLift ''IdMaker
PlutusTx.unstableMakeIsData ''IdMaker

data GovernanceDatum = GProposal Proposal | GOwnership Ownership | GTokenTrace TokenTrace | GIdMaker IdMaker
    deriving (Show, Generic, FromJSON, ToJSON)

PlutusTx.makeLift ''GovernanceDatum
PlutusTx.unstableMakeIsData ''GovernanceDatum

{-# INLINABLE ownershipDatum #-}
ownershipDatum :: TxInfo -> TxOut -> Maybe Ownership
ownershipDatum txInfo o = do
    dh      <- txOutDatum o
    Datum d <- findDatum dh txInfo
    PlutusTx.fromBuiltinData d

{-# INLINABLE proposalDatum #-}
proposalDatum :: TxInfo -> TxOut -> Maybe Proposal
proposalDatum txInfo o = do
    dh      <- txOutDatum o
    Datum d <- findDatum dh txInfo
    PlutusTx.fromBuiltinData d

{-# INLINABLE traceDatum #-}
traceDatum :: TxInfo -> TxOut -> Maybe TokenTrace
traceDatum txInfo o = do
    dh      <- txOutDatum o
    Datum d <- findDatum dh txInfo
    PlutusTx.fromBuiltinData d

{-# INLINABLE idMakerDatum #-}
idMakerDatum :: TxInfo -> TxOut -> Maybe IdMaker
idMakerDatum txInfo o = do
    dh      <- txOutDatum o
    Datum d <- findDatum dh txInfo
    PlutusTx.fromBuiltinData d

{-# INLINABLE idMakerContinues #-}
idMakerContinues :: TxInfo -> [TxOut] -> Bool
idMakerContinues txInfo idConOuts =
    let
        idOut = head idConOuts
        idOutDatum = idMakerDatum txInfo idOut
    in
        case idOutDatum of
            Just d  -> True
            Nothing -> False

{-# INLINABLE validDatumOutput #-}
validDatumOutput :: TxInfo -> TxOut -> Bool
validDatumOutput txInfo tx =
    let
        idOutDatum = idMakerDatum txInfo tx
        ownerOut = ownershipDatum txInfo tx
        nftOut = traceDatum txInfo tx
        proposalOut = proposalDatum txInfo tx
    in
        case (idOutDatum, ownerOut, nftOut, proposalOut) of
            (Nothing, Nothing, Nothing, Just p) -> True
            (Nothing, Nothing, Just t, Nothing) -> True
            (Nothing, Just o, Nothing, Nothing) -> True
            (Just i, Nothing, Nothing, Nothing) -> True
            _                                   -> False

{-# INLINABLE validDatumOutputs #-}
validDatumOutputs :: TxInfo -> [TxOut] -> Bool
validDatumOutputs txInfo continuingOutputs = [tx | tx <- continuingOutputs, validDatumOutput txInfo tx] == continuingOutputs

-- We need to make sure that our tokens of type prop or of type vote are all accounted for and are returned to the script.
{-# INLINABLE noIdsLeaveScript #-}
noIdsLeaveScript :: AssetClass -> AssetClass -> [TxOut] -> [TxOut] -> Bool
noIdsLeaveScript propclass voteclass txOuts continuingOutputs = [tx | tx <- txOuts, ((assetClassValueOf (txOutValue tx) propclass > 0) || (assetClassValueOf (txOutValue tx) voteclass > 0))] == [tx | tx <- continuingOutputs, ((assetClassValueOf (txOutValue tx) propclass > 0) || (assetClassValueOf (txOutValue tx) voteclass > 0))]

-- This simply checks all of the Datum values coming from the script and if there are any then it returns true.
{-# INLINABLE ownershipDatumPresent #-}
ownershipDatumPresent :: TxInfo -> [TxInInfo] -> Bool
ownershipDatumPresent txInfo txIns = [tx | tx <- txIns, PlutusTx.Maybe.isJust (ownershipDatum txInfo (txInInfoResolved tx))] /= []

{-# INLINABLE oldEnoughOwnership #-}
oldEnoughOwnership :: Maybe Ownership -> Maybe Proposal -> Bool
oldEnoughOwnership o p = case o of
    Just od  ->
        case p of
            Just pd ->
                let
                    t = lastTransfer od
                    ps = proposalStart pd
                in
                    contains (from t) (from ps)
            Nothing -> False
    Nothing -> False
        
-- This makes sure that all UTxOs containing ownership tokens are old enough to be participating in the vote that they're attending.
{-# INLINABLE oldEnoughInput #-}
oldEnoughInput :: TxInfo -> [TxInInfo] -> [TxInInfo] -> Bool
oldEnoughInput txInfo voteTxos propTxos =
    let
        proposal = proposalDatum txInfo (txInInfoResolved (propTxos !! 0))
        voteTxs = map txInInfoResolved voteTxos
    in
        [txo | txo <- voteTxs, (oldEnoughOwnership (ownershipDatum txInfo txo) proposal)] == voteTxs

-- This checks the proposal to see if amount of time that has passed is adequate to skip the numberOfVotesMet.
{-# INLINABLE epochsPassed #-}
epochsPassed :: TxInfo -> Maybe Proposal -> Bool
epochsPassed txInfo mp = case mp of
    Just p  ->
        let
            ps = proposalStart p
            d5 = 432000 -- This is 5 days in seconds x 10 for POSIX Conversion
            h2 = 7200 -- 120 * 60
        in
            contains (from (ps + h2)) (txInfoValidRange txInfo)
    Nothing -> False

-- If we add a thing to track the number of minted gov tokens into the script Datum we can use this to denote the hardset numbers. One thing at a time though right?
{-# INLINABLE numberOfVotesMet #-}
numberOfVotesMet :: TxInfo -> [TxInInfo] -> [TxInInfo] -> Bool
numberOfVotesMet txInfo propTxos nftTxos =
    let
        proposal = proposalDatum txInfo (txInInfoResolved (propTxos !! 0))
        nft = traceDatum txInfo (txInInfoResolved (nftTxos !! 0))
    in
        case proposal of
            Just proposal -> case nft of
                Just nft -> (yes proposal + no proposal) % (tMinted nft - treasuryValue nft) > 5 % 10
                Nothing  -> False
            Nothing       -> False

-- This just checks to see that there is enough of a ratio between yes and no.
{-# INLINABLE highEnoughRatio #-}
highEnoughRatio :: TxInfo -> [TxInInfo] -> Bool
highEnoughRatio txInfo propTxos =
    let
        proposal = proposalDatum txInfo (txInInfoResolved (propTxos !! 0))
    in
        case proposal of
            Just proposal -> (yes proposal % no proposal) > 51 % 49
            Nothing       -> False

{-# INLINABLE validOwnerOutput' #-}
validOwnerOutput' :: TxInfo -> Ownership -> Bool
validOwnerOutput' txInfo d = contains (txInfoValidRange txInfo) (from (lastTransfer d + 120))
        
{-# INLINABLE validOwnerOutput #-}
validOwnerOutput :: TxInfo -> Maybe Ownership -> Bool
validOwnerOutput txInfo md = case md of
    Just d  -> validOwnerOutput' txInfo d
    Nothing -> False

{-# INLINABLE getTheOwnershipDatum #-}
getTheOwnershipDatum :: TxInfo -> TxInInfo -> (TxInInfo, Ownership)
getTheOwnershipDatum txInfo tx =
    let
        oData = ownershipDatum txInfo (txInInfoResolved tx)
    in
        case oData of
            Just o -> (tx, o)
            Nothing -> traceError ""
        
-- This makes sure that all UTxOs containing OwnershipDatum are sent to the correct place with the correct timestamps.
-- If the UTxO is also contained in voteTxos then the time
-- This makes sure the datum inputs from above also have the corresponding output UTxO: either at the script or at the owners address.
-- It also requires the owners signature on the transaction for these to be spent.
-- It also requires that the output Datum is within 120 seconds +/- of the time that the transaction is submitted on-chain.
{-# INLINABLE ensureOwnershipOutputs #-}
ensureOwnershipOutputs :: TxInfo -> [TxInInfo] -> Bool
ensureOwnershipOutputs txInfo txIns =
    let
        ownershipInputs = [tx | tx <- txIns, PlutusTx.Maybe.isJust (ownershipDatum txInfo (txInInfoResolved tx))]
        ownershipAndDatum = map (getTheOwnershipDatum txInfo) ownershipInputs
        ownershipSigned = [tx | (tx, o) <- ownershipAndDatum, (txSignedBy txInfo $ owner o)]
        ownershipOutputDatums = [ownershipDatum txInfo tx | tx <- (txInfoOutputs txInfo), PlutusTx.Maybe.isJust (ownershipDatum txInfo tx)]
        validOutputs = [validOwnerOutput txInfo datum | datum <- ownershipOutputDatums, PlutusTx.Maybe.isJust datum]
    in
        ownershipInputs == ownershipSigned &&
        and validOutputs

{-# INLINABLE compareProposals' #-}
compareProposals' :: Integer -> Proposal -> Proposal -> Bool
compareProposals' votes before after =
    (proposalStart before) == (proposalStart after) &&
    (scriptUpdate before) == (scriptUpdate after) &&
    (scriptAddr before) == (scriptAddr after) &&
    (spend before) == (spend after) &&
    (spendValue before) == (spendValue after) &&
    (spendAddr before) == (spendAddr after) &&
    (minting before) == (minting after) &&
    (minted before) == (minted after) &&
    (yes before) <= (yes after) &&
    (no before) <= (no after) &&
    (yes after + no after) - (yes before + no before) == votes

{-# INLINABLE compareProposals #-}
compareProposals :: Integer -> Maybe Proposal -> Maybe Proposal -> Bool
compareProposals votes before after = case before of
    Just b  ->
        case after of
            Just a  -> traceIfFalse "Comparing Proposals failed." (compareProposals' votes b a)
            Nothing -> False
    Nothing -> False

-- This function validates the updating of the proposal datum.
{-# INLINABLE correctPropOutputs #-}
correctPropOutputs :: AssetClass -> Integer -> TxInfo -> [TxOut] -> Bool
correctPropOutputs propclass votes txInfo propTxos =
    let
        propIn = propTxos !! 0
        propOuts = [txo | txo <- (txInfoOutputs txInfo), (assetClassValueOf (txOutValue $ txo) propclass > 0)]
        propOut = propOuts !! 0
    in
        if (length propTxos) > 1 || (length propOuts) > 1 then False else
            traceIfFalse "The high-level proposal compare failed." (compareProposals votes (proposalDatum txInfo propIn) (proposalDatum txInfo propOut))

{-# INLINABLE checkOnePath' #-}
checkOnePath' :: Integer -> Integer -> Bool
checkOnePath' s m = s + m < 2

{-# INLINABLE checkOnePath #-}
checkOnePath :: Proposal -> Bool
checkOnePath p =
    let
        spending = spend p
        minting' = minting p
        -- updating = checkIfScriptSpent
        s = if spending then 1 else 0
        m = if minting' then 1 else 0
    in
        traceIfFalse "The Proposal does too many things to be valid." (checkOnePath' s m)

-- The treasury must spend the right amount.
-- No Update or Minting may occur.
{-# INLINABLE checkScriptTreasuryUse #-}
checkScriptTreasuryUse :: Address -> AssetClass -> TxInfo -> [TxInInfo] -> [TxOut] -> [TxOut] -> Proposal -> Bool
checkScriptTreasuryUse treasury nft txInfo txIns txOuts continuingOutputs p =
    let
        spent = spendValue p
        spendAddress = spendAddr p
        treasuryIns = [tx | tx <- txIns, ((txOutAddress $ txInInfoResolved tx) == treasury)]
        treasuryIn = treasuryIns !! 0
        val = txOutValue (txInInfoResolved treasuryIn)
        spendOuts = [tx | tx <- txOuts, ((txOutAddress tx == spendAddress) && (txOutValue tx == spent) && (txOutValue tx == val))]
        mintVal = txInfoMint txInfo
        nftOuts = [tx | tx <- txOuts, (assetClassValueOf (txOutValue tx) nft > 0)]
        nftOut = nftOuts !! 0
    in -- Make sure only one in TxO for the treasury and one out for the treasury with the right value and the right address.
        -- This is going to allow for multiple outputs in the same proposal in the future. Taken out for now to reduce complexity.
        traceIfFalse "There is not a single treasury input." (length treasuryIns == 1) &&
        traceIfFalse "The spentOuts is not of length 1." (length spendOuts == 1) &&
        traceIfFalse "The minting value is non-zero in treasury usage." (mintVal == Ada.lovelaceValueOf 0) &&
        traceIfFalse "The NFT is not an element in continuing outputs." (elem nftOut continuingOutputs)

-- The script UTxO must be updated on both fields by the amount. Minted tokens must go to the treasury.
-- No Update or Spending may occur.
{-# INLINABLE checkScriptMintingUse #-}
checkScriptMintingUse :: Address -> AssetClass -> TxInfo -> [TxInInfo] -> [TxOut] -> [TxOut] -> Proposal -> Bool
checkScriptMintingUse treasury nft txInfo txIns txOuts continuingOutputs p =
    let
        treasuryIns = [tx | tx <- txIns, ((txOutAddress $ txInInfoResolved tx) == treasury)]
        nftOuts = [tx | tx <- txOuts, (assetClassValueOf (txOutValue tx) nft > 0)]
        mintVal = txInfoMint txInfo
        nftOut = nftOuts !! 0
        continuingWithMint = [tx | tx <- txOuts, ((txOutValue tx) == mintVal && (txOutAddress tx) == treasury)]
    in
        traceIfFalse "The length of the treasury is non-zero in minting usage." (length treasuryIns == 0) &&
        traceIfFalse "The NFT is not an element of continuingOutputs." (elem nftOut continuingOutputs) &&
        traceIfFalse "The length of the continuing mint is not 1." (length continuingWithMint == 1)

-- The NFT must go to the specified address
-- The Treasury cannot be spent from.
-- No minting may occur.
{-# INLINABLE checkScriptUpdate #-}
checkScriptUpdate :: Address -> AssetClass -> TxInfo -> [TxInInfo] -> [TxOut] -> Proposal -> Bool
checkScriptUpdate treasury nft txInfo txIns txOuts p =
    let
        treasuryIns = [tx | tx <- txIns, ((txOutAddress $ txInInfoResolved tx) == treasury)]
        nftOuts = [tx | tx <- txOuts, (assetClassValueOf (txOutValue tx) nft > 0)]
        nftOut = nftOuts !! 0
        mintVal = txInfoMint txInfo
        nftAddress = txOutAddress nftOut
    in
        traceIfFalse "The length of treasury in is non-zero during update." (length treasuryIns == 0) &&
        traceIfFalse "The minting value is non-zero" (mintVal == Ada.lovelaceValueOf 0) &&
        traceIfFalse "The nft goes to a different address than specified by the proposal." (nftAddress == scriptAddr p)

{-# INLINABLE checkScriptOutputs' #-}
checkScriptOutputs' :: Address -> AssetClass -> TxInfo -> [TxInInfo] -> [TxOut] -> [TxOut] -> Proposal -> Bool
checkScriptOutputs' treasury nft txInfo txIns txOuts continuingOutputs p =
    if spend p then
        checkScriptTreasuryUse treasury nft txInfo txIns txOuts continuingOutputs p
    else if minting p then
        checkScriptMintingUse treasury nft txInfo txIns txOuts continuingOutputs p
    else
        checkScriptUpdate treasury nft txInfo txIns txOuts p

-- This function validates the spending from the DAO Treasury
-- This function validates the minting to the DAO Treasury
-- This function validates the spending of the DAO NFT.
{-# INLINABLE correctScriptOutputs #-}
correctScriptOutputs :: Address -> AssetClass -> TxInfo -> [TxInInfo] -> [TxOut] -> [TxOut] -> [TxInInfo] -> Bool
correctScriptOutputs treasury nft txInfo txIns txOuts continuingOutputs propTxos =
    let
        propIn = proposalDatum txInfo (txInInfoResolved (propTxos !! 0))
    in
        if (length propTxos) /= 1 then False else
            case propIn of
                Just p  ->
                    checkOnePath p &&
                    checkScriptOutputs' treasury nft txInfo txIns txOuts continuingOutputs p
                _ -> False

{-# INLINABLE votingPassValidator #-}
votingPassValidator :: ValidatorHash -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> GovernanceDatum -> BuiltinData -> ScriptContext -> Bool
votingPassValidator treasury govClass nft idMaker propclass voteclass datum r ctx =
  let
      txInfo = scriptContextTxInfo ctx

      treasuryAddr = scriptHashAddress treasury

      -- We map over all of the inputs to the transaction to gather the number of votes present.
      txIns = txInfoInputs $ scriptContextTxInfo ctx
      txInValues = [txOutValue $ txInInfoResolved txIn | txIn <- txIns]
      txOuts = txInfoOutputs txInfo
      continuingOutputs = getContinuingOutputs ctx
      tokenValues = [assetClassValueOf val govClass | val <- txInValues]
      votes = sum tokenValues -- sum the occurrences of the tokenClass inside of txInValues.
      nftValues = [assetClassValueOf val nft | val <- txInValues]
      nftPresent = (sum nftValues > 0) -- sum the occurrences of the tokenClass inside of txInValues.
      nftTxos = [txo | txo <- txIns, assetClassValueOf (txOutValue $ txInInfoResolved txo) nft > 0]
      idMakers = [txo | txo <- txIns, assetClassValueOf (txOutValue $ txInInfoResolved txo) idMaker > 0]
      propTxos = [txo | txo <- txIns, assetClassValueOf (txOutValue $ txInInfoResolved txo) propclass > 0]
      proposal = proposalDatum txInfo (head [txInInfoResolved tx | tx <- propTxos])
      proposalPresent = propTxos /= []
      voteTxos = [txo | txo <- txIns, assetClassValueOf (txOutValue $ txInInfoResolved txo) voteclass > 0]
      idOuts = [tx | tx <- txOuts, assetClassValueOf (txOutValue tx) idMaker > 0]
      idConOuts = [tx | tx <- continuingOutputs, assetClassValueOf (txOutValue tx) idMaker > 0]
  in
      noIdsLeaveScript propclass voteclass txOuts continuingOutputs &&
      validDatumOutputs txInfo continuingOutputs &&
      if not (null idMakers) then
          --traceIfFalse "IdMaker present but doesn't continue." (idMakerContinues txInfo idConOuts) &&
          traceIfFalse "IdMaker is present in output but not in the script." (idOuts == idConOuts) &&
          traceIfFalse "The NFT is present in an IdGen tx." (not nftPresent) &&
          traceIfFalse "A Proposal is present in an IdGen tx." (not proposalPresent) &&
          traceIfFalse "There are already ownership tokens present in the input." (null voteTxos)
      else
          traceIfFalse "An issue with an owned input occurred. Output issue likely."
          (not (ownershipDatumPresent txInfo txIns) || ensureOwnershipOutputs txInfo txIns) &&
          traceIfFalse "An issue with the NFT or Proposal occured.." ((not nftPresent ||
          -- Here we need to make sure that: There are enough votes to push the vote forward, and that there is enough of a yes:no ratio.
          (proposalPresent && -- This just makes sure that the proposal is present.
              correctScriptOutputs treasuryAddr nft txInfo txIns txOuts continuingOutputs propTxos && -- This needs to check spending from the treasury -- Also checks any minted gov tokens -> Goes to treasury. -- Prop to burn?
              epochsPassed txInfo proposal &&
              numberOfVotesMet txInfo propTxos nftTxos && -- This makes sure the votes are correct.
              highEnoughRatio txInfo propTxos)) || -- Verify that only funds allow to be spent are spent. -- We don't check that the time has passed in this contract. TODO
          (not proposalPresent ||
          (oldEnoughInput txInfo voteTxos propTxos &&
              correctPropOutputs propclass votes txInfo txOuts)))

-- We need this because we are returning a Boolean above.
data Voting
instance Scripts.ValidatorTypes Voting where
    type instance DatumType Voting = GovernanceDatum -- Proposal | Owner | TokenTrace | IdMaker
    type instance RedeemerType Voting = BuiltinData

-- This section allows for the code above to be easily compiled to the information necessary to deploy on chain.
votingPassValidatorInstance :: ValidatorHash -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> Scripts.TypedValidator Voting
votingPassValidatorInstance treasury govClass nft idMaker propclass voteclass  = Scripts.mkTypedValidator @Voting
    ($$(PlutusTx.compile [|| votingPassValidator ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode treasury
    `PlutusTx.applyCode`
    PlutusTx.liftCode govClass
    `PlutusTx.applyCode`
    PlutusTx.liftCode nft
    `PlutusTx.applyCode`
    PlutusTx.liftCode idMaker
    `PlutusTx.applyCode`
    PlutusTx.liftCode propclass
    `PlutusTx.applyCode`
    PlutusTx.liftCode voteclass)
    $$(PlutusTx.compile [|| wrap ||]) where
        wrap = Scripts.wrapValidator @GovernanceDatum @BuiltinData

votingPassValidatorHash :: ValidatorHash -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> ValidatorHash
votingPassValidatorHash treasury govClass nft idMaker propclass voteclass = Scripts.validatorHash $ votingPassValidatorInstance treasury govClass nft idMaker propclass voteclass

votingPassValidatorScript :: ValidatorHash -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> Validator
votingPassValidatorScript treasury govClass nft idMaker propclass voteclass = Scripts.validatorScript $ votingPassValidatorInstance treasury govClass nft idMaker propclass voteclass

votingPassScriptAddress :: ValidatorHash -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> AssetClass -> Address
votingPassScriptAddress treasury govClass nft idMaker propclass voteclass = Ledger.scriptAddress $ votingPassValidatorScript treasury govClass nft idMaker propclass voteclass

{-- We need to create the proposal using the IdMaker NFT so that it will be valid, also ensure a valid proposal..
data CreateProposal = CreateProposal
    { proposalStart :: !POSIXTime
    , scriptUpdate  :: !Bool
    , scriptAddr    :: Address
    , spend         :: !Bool
    , spendValue    :: Value
    , spendAddr     :: Address
    , minting       :: !Bool
    , minted        :: Integer
    } deriving (Show, Generic, FromJSON, ToJSON)

createProposal :: forall w s. CreateProposal -> Contract w s Text ()
createProposal cp = do
    scriptPubKeyHash <- pubKeyHash <$> Contract.ownPubKey
    let proposal = Proposal
            { proposalStart = proposalStart cp
            , scriptUpdate  = scriptUpdate cp
            , scriptAddr = scriptAddr cp
            , spend = spend cp
            , spendValue = spendValue cp
            , spendAddr = spendAddr cp
            , minting = minting cp
            , minted = minted cp
            , yes = 0
            , no = 0
            } --}
        
-- We need to create the Ownership Datum UTxO with the IdMaker NFT so that it will be valid for use in proposals.
data CreateOwnerId = CreateOwnerId
    { createOwner :: !PubKeyHash
    } deriving (Show, Generic, FromJSON, ToJSON)

createOwnerId :: forall w s. CreateOwnerId -> Contract w s Text ()
createOwnerId co = do
    scriptPubKeyHash <- Contract.ownPubKeyHash
    now <- currentTime
    -- utxos <- Map.filter idIdMaker <$> utxoAt
    let ownership = Ownership
            { owner = createOwner co
            , nftSlot = now
            , lastTransfer = now
            }
    Contract.logInfo @String $ printf "Created Ownership: %s" (show ownership)
  where
    isIdMaker :: TxOutTx -> Bool
    isIdMaker o = True

-- We need to create a transaction that if going to the script will contain the Id for the script,
--data ShiftOwnership = ShiftOwnership
-- We need to apply owned votes with the proposal and send all votes back to the script with the ownership FT attached.
--data ApplyVotes = ApplyVotes
-- We need to check to see what type of proposal is being executed, this should be done through an input of a proposal datum..?
--data ExecuteProposal = ExecuteProposal