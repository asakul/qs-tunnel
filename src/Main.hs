{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.List as L
import Data.List.NonEmpty
import Data.IORef
import Data.Time.Clock
import Data.Aeson

import ATrade.QuoteSource.Server
import ATrade.QuoteSource.Client

import Control.Monad
import Control.Monad.Loops

import System.IO
import System.Log.Logger
import System.Log.Handler.Simple
import System.Log.Handler (setFormatter)
import System.Log.Formatter
import System.ZMQ4
import System.ZMQ4.ZAP

data Config = Config
  {
    confDownstreamEp :: T.Text,
    confWhitelistIps :: [T.Text],
    confBlacklistIps :: [T.Text],
    confUpstreamEp :: T.Text,
    confTimeout :: Integer
  } deriving (Show, Eq)

instance FromJSON Config where
  parseJSON (Object o) =
    Config                      <$>
    o .:  "downstream"          <*>
    o .:? "whitelist"   .!= []  <*>
    o .:? "blacklist"   .!= []  <*>
    o .:  "upstream"            <*>
    o .:  "timeout"

  parseJSON _ = fail "Expected object"

initLogging = do
  handler <- streamHandler stderr DEBUG >>=
    (\x -> return $
      setFormatter x (simpleLogFormatter "$utcTime\t {$loggername} <$prio> -> $msg"))

  hSetBuffering stderr LineBuffering
  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  updateGlobalLogger rootLoggerName (setHandlers [handler])

main :: IO ()
main = do
  initLogging
  infoM "main" "Starting"
  eConf <- eitherDecode . BL.fromStrict <$> B.readFile "qs-tunnel.conf" 
  case eConf of
    Left errMsg -> error errMsg
    Right conf -> runWithConfig conf

runWithConfig conf = do
  withContext $ \ctx ->
    withSocket ctx Pub $ \downstream -> do
      bind downstream $ T.unpack $ confDownstreamEp conf

      forever $ withSocket ctx Sub $ \upstream -> do
        infoM "main" $ "Connecting to: " ++ (T.unpack $ confUpstreamEp conf)
        connect upstream $ T.unpack $ confUpstreamEp conf
        subscribe upstream B.empty
        now <- getCurrentTime
        lastHeartbeat <- newIORef now
        lastHeartbeatSent <- newIORef now
        infoM "main" "Starting proxy loop"
        whileM (notTimeout lastHeartbeat conf) $ do
          evs <- poll 200 [Sock upstream [In] Nothing] 
          sendHeartbeatIfNeeded lastHeartbeatSent downstream
          unless (null (L.head evs)) $ do
            incoming <- receiveMulti upstream
            case incoming of
              x:xs -> do
                now <- getCurrentTime
                writeIORef lastHeartbeat now
                sendMulti downstream $ x :| xs
              _ -> return ()
   where
     notTimeout ref conf = do
       now <- getCurrentTime
       lastHb <- readIORef ref
       return $ now `diffUTCTime` lastHb < (fromInteger . confTimeout) conf

     sendHeartbeatIfNeeded lastHbSent sock = do
       now <- getCurrentTime
       last <- readIORef lastHbSent
       when (now `diffUTCTime` last > 1) $ do
         send sock [] $ B8.pack "SYSTEM#HEARTBEAT"
         writeIORef lastHbSent now
         

