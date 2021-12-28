{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
module Discord.Internal.Voice.WebsocketLoop where

import Control.Concurrent.Async ( race )
import Control.Concurrent
    ( Chan
    , newChan
    , writeChan
    , readChan
    , threadDelay
    , forkIO
    , killThread
    , MVar
    , putMVar
    , tryReadMVar
    , newEmptyMVar
    , tryTakeMVar
    , ThreadId
    , myThreadId
    , modifyMVar_
    , newMVar
    , readMVar
    , mkWeakThreadId
    )
import Control.Exception.Safe ( try, SomeException, finally, handle )
import Control.Lens
import Control.Monad ( forever, guard )
import Control.Monad.IO.Class ( liftIO )
import Control.Monad.Except ( runExceptT, ExceptT (ExceptT) )
import Control.Monad.Trans ( lift )
import Data.Aeson ( encode, eitherDecode )
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX
import Data.Word ( Word16 )
import Network.WebSockets
    ( ConnectionException(..)
    , Connection
    , sendClose
    , receiveData
    , sendTextData
    )
import Wuss ( runSecureClient )

import Discord
import Discord.Internal.Gateway ( GatewayException )
import Discord.Internal.Types ( GuildId, UserId, User(..), Event(..) )
import Discord.Internal.Types.VoiceCommon
import Discord.Internal.Types.VoiceWebsocket
import Discord.Internal.Types.VoiceUDP
import Discord.Internal.Voice.CommonUtils
import Discord.Internal.Voice.UDPLoop

data WSState
    = WSStart
    | WSClosed
    | WSResume
    deriving Show

-- | A custom logging function that writes the date/time and the thread ID.
(✍) :: Chan T.Text -> T.Text -> IO ()
logChan ✍ log = do
    t <- formatTime defaultTimeLocale "%F %T %q" <$> getCurrentTime
    tid <- myThreadId
    writeChan logChan $ (T.pack t) <> " " <> (tshow tid) <> " " <> log

-- | A variant of (✍) that prepends the wsError text.
(✍!) :: Chan T.Text -> T.Text -> IO ()
logChan ✍! log = logChan ✍ ("!!! Voice Websocket Error - " <> log)

-- Alias for running a websocket connection using the Discord endpoint URL
-- (which contains the port as well). Makes sure to connect to the correct
-- voice gateway version as well, as the default version of 1 is severely out of
-- date (the opcode behaviours are not according to docs).
connect :: T.Text -> (Connection -> IO a) -> IO a
connect endpoint = runSecureClient url port "/?v=4"
  where
    url = (T.unpack . T.takeWhile (/= ':')) endpoint
    port = (read . T.unpack . T.takeWhileEnd (/= ':')) endpoint

-- | Attempt to connect (and reconnect on disconnects) to the voice websocket.
-- Also launches the UDP thread after the initialisation.
launchWebsocket :: WebsocketLaunchOpts -> Chan T.Text -> IO ()
launchWebsocket opts log = do
    -- Keep an MVar (only for use in this function), to store the UDP launch
    -- options across Resume events.
    udpOpts <- newMVar undefined
    websocketFsm WSStart 0 udpOpts
  where
    websocketFsm :: WSState -> Int -> MVar UDPLaunchOpts -> IO ()
    -- Websocket closed legitimately. The UDP thread and this thread
    -- will be closed by the cleanup in runVoice.
    websocketFsm WSClosed retries udpInfo = pure ()

    -- First time. Let's open a Websocket connection to the Voice
    -- Gateway, do the initial Websocket handshake routine, then
    -- ask to open the UDP connection.
    -- When creating the UDP thread, we will fill in the MVars in
    -- @opts@ to report back to runVoice, so it can be killed in the
    -- future.
    websocketFsm WSStart retries udpInfo = do
        next <- try $ connect (opts ^. endpoint) $ \conn -> do
            (libSends, sendTid) <- flip (setupSendLoop conn) log $ opts ^. wsHandle . _2
            
            result <- runExceptT $ do
                helloPacket <- ExceptT $
                    over _Left ((<> "Failed to get Opcode 8 Hello: ") . tshow) <$>
                    getPayload conn

                interval <- ExceptT $ pure $
                    maybeToRight ("First packet not Opcode 8 Hello: " <> tshow helloPacket) $
                        helloPacket ^? _Hello

                -- Create a thread to add heartbeating packets to the
                -- libSends Chan.
                heartGenTid <- lift $ forkIO $ heartbeatLoop libSends interval log
                -- Perform the Identify/Ready handshake
                readyPacket <- ExceptT $
                    over _Left ((<> "Failed to get Opcode 2 Ready: ") . tshow) <$>
                    performIdentification conn opts

                p <- ExceptT $ pure $
                    maybeToRight ("First packet after Identify not " <> "Opcode 2 Ready " <> tshow readyPacket) $
                        readyPacket ^? _Ready

                secretKey <- lift $ newEmptyMVar
                let udpLaunchOpts = UDPLaunchOpts
                        { uDPLaunchOptsSsrc      = readyPayloadSSRC p
                        , uDPLaunchOptsIp        = readyPayloadIP p
                        , uDPLaunchOptsPort      = readyPayloadPort p
                        , uDPLaunchOptsMode      = "xsalsa20_poly1305"
                        , uDPLaunchOptsUdpHandle = opts ^. udpHandle
                        , uDPLaunchOptsSecretKey = secretKey
                        -- TODO: support all encryption modes
                        }
                -- We should be putting SSRC into the MVar to report back to
                -- the websocket (TODO: why was this again), but we hold it off
                -- until the ssrcCheck guard a few lines below.
                lift $ modifyMVar_ udpInfo (pure . const udpLaunchOpts)
                            
                -- Pass not the MVar but the raw options, since
                -- there's no writing to be done.
                flip finally (lift $ killThread heartGenTid >> killThread sendTid) $ do
                    -- Launch the UDP thread, automatically perform 
                    -- IP discovery, which will write the result
                    -- to the receiving Chan.
                    forkedId <- lift $ forkIO $ launchUdp udpLaunchOpts log
                    udpTidWeak <- liftIO $ mkWeakThreadId forkedId
                    lift $ putMVar (opts ^. udpTid) udpTidWeak

                    ipDiscovery <- lift $ readChan $ opts ^. udpHandle . _1
                    (ssrcCheck, ip, port) <- ExceptT $ pure $
                        maybeToRight ("First UDP Packet not IP Discovery " <> tshow ipDiscovery) $
                            ipDiscovery ^? _IPDiscovery
                    
                    guard (ssrcCheck == udpLaunchOpts ^. ssrc)
                    lift $ putMVar (opts ^. ssrc) ssrcCheck
                    
                    -- TODO: currently, we await the Opcode 4 SD right after
                    -- Select Protocol, blocking the start of heartbeats until
                    -- eventStream. This means there's a delay, so TODO to check
                    -- if this delay causes any problems. If it does, keep the
                    -- sending here, but receive the SD event in eventStream.
                    sessionDescPacket <- ExceptT $
                        over _Left ((<> "Failed to get Opcode 4 SD: ") . tshow) <$>
                            sendSelectProtocol conn ip port (udpLaunchOpts ^. mode)
                    
                    (modeCheck, key) <- ExceptT $ pure $
                        maybeToRight ("First packet after Identify not " <> "Opcode 2 Ready " <> tshow readyPacket) $
                            sessionDescPacket ^? _SessionDescription
                    
                    guard (modeCheck == udpLaunchOpts ^. mode)

                    lift $ putMVar secretKey key

                    -- Move to eternal websocket event loop, mainly for the
                    -- heartbeats, but also for any user-generated packets.
                    lift $ eventStream conn opts interval udpLaunchOpts libSends log

            case result of
                Left reason -> log ✍! reason >> pure WSClosed
                Right state -> pure state

        -- Connection is now closed.
        case next :: Either SomeException WSState of
            Left e -> do
                (✍!) log $ "could not connect due to an exception: " <>
                    (tshow e)
                writeChan (opts ^. wsHandle . _1) $ Left $
                    VoiceWebsocketCouldNotConnect
                        "could not connect due to an exception"
                websocketFsm WSClosed 0 udpInfo
            Right n -> websocketFsm n 0 udpInfo

    websocketFsm WSResume retries udpInfo = do
        next <- try $ connect (opts ^. endpoint) $ \conn -> do
            (libSends, sendTid) <- flip (setupSendLoop conn) log $ opts ^. wsHandle . _2
            helloPacket <- getPayload conn
            case helloPacket of
                Left e -> do
                    (✍!) log $ "Failed to get Opcode 8 Hello: " <> (tshow e)
                    pure WSClosed
                Right (Hello interval) -> do
                    -- Create a thread to add heartbeating packets to the
                    -- libSends Chan.
                    heartGenTid <- forkIO $ heartbeatLoop libSends interval log
                    -- Perform the Resume/Resumed handshake
                    resumedPacket <- performResumption conn opts
                    case resumedPacket of
                        Left e -> do
                            (✍!) log $ "Failed to get Opcode 9 Resumed: " <> (tshow e)
                            pure WSClosed
                        Right (Discord.Internal.Types.VoiceWebsocket.Resumed) -> do
                            -- use the previous UDP launch options since it's not resent
                            udpLaunchOpts <- readMVar udpInfo
                            
                            -- Pass not the MVar but the raw options, since
                            -- there's no writing to be done.
                            finally (eventStream conn opts interval udpLaunchOpts libSends log) $
                                (killThread heartGenTid >> killThread sendTid)
                        Right p -> do
                            (✍!) log $ "First packet after Resume not " <> 
                                "Opcode 9 Resumed: " <> (tshow p)
                            pure WSClosed
                Right p -> do
                    (✍!) log $ "First packet not Opcode 8 Hello: " <> (tshow p)
                    pure WSClosed

        -- Connection is now closed.
        case next :: Either SomeException WSState of
            Left _ -> do
                (✍!) log $ "could not resume, retrying after 5 seconds"
                threadDelay $ 5 * (10^(6 :: Int))
                websocketFsm WSResume (retries + 1) udpInfo
            Right n -> websocketFsm n 1 udpInfo

-- | Create the library-specific sending packets Chan, and then create the
-- thread for eternally sending contents in the said Chan, as well as the
-- user-generated packet Chan.
-- loop for
-- the websocket.
setupSendLoop
    :: Connection
    -- ^ Connection to use
    -> VoiceWebsocketSendChan
    -- ^ User generated packets to send in the Websocket
    -> Chan T.Text
    -- ^ Logging channel
    -> IO (VoiceWebsocketSendChan, ThreadId)
    -- ^ Chan to send library-specific packets in the Websocket, and the thread
    -- ID of the eternal sending thread (useful for killing it).
setupSendLoop conn userSends log = do
    -- The following Chan will be used for accumulating library-generated
    -- WebSocket messages that we need to send to Discord, mostly for heartbeats.
    libSends <- newChan
    -- Start said eternal sending fork, which will eternally send from library-
    -- generated and user-generated packets.
    sendLoopId <- forkIO $ sendableLoop conn libSends userSends log

    pure (libSends, sendLoopId)

-- | Send the Opcode 0 Identify packet to Discord, and await the Opcode 2 Ready
-- payload, which contains the UDP connection info.
performIdentification
    :: Connection
    -> WebsocketLaunchOpts
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
performIdentification conn opts = do
    -- Send opcode 0 Identify
    sendTextData conn $ encode $ Identify $ IdentifyPayload
        { identifyPayloadServerId = (opts ^. guildId)
        , identifyPayloadUserId = (opts ^. botUserId)
        , identifyPayloadSessionId = (opts ^. sessionId)
        , identifyPayloadToken = (opts ^. token)
        }
        
    getPayload conn

-- | Send the Opcode 7 Resume packet to Discord, and await the Opcode 9 Resumed
-- payload.
performResumption
    :: Connection
    -> WebsocketLaunchOpts
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
performResumption conn opts = do
    -- Send opcode 7 Resume
    sendTextData conn $ encode $
        Resume (opts ^. guildId) (opts ^. sessionId) (opts ^. token)
    
    getPayload conn

-- | Send the Opcode 1 Select Protocol to Discord. Does not wait for a payload.
sendSelectProtocol
    :: Connection
    -> T.Text
    -> Integer
    -> T.Text
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
sendSelectProtocol conn ip port mode = do
    sendTextData conn $ encode $ SelectProtocol $ 
        SelectProtocolPayload "udp" ip port mode
    
    getPayload conn

    -- We do not do getPayload here, since there's no guarantee the next
    -- received packet is an Opcode 4 Session Description, when heartbeats
    -- has began already.
    -- TODO: remove if the above is not a problem

-- | Get one packet from the Websocket Connection, parsing it into a
-- VoiceWebsocketReceivable using Aeson. If the packet is not validly
-- parsed, it will be a @Right (ParseError info)@.
getPayload
    :: Connection
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
getPayload conn = try $ do
    msg' <- receiveData conn
    case eitherDecode msg' of
        Right msg -> pure msg
        Left err  -> pure $ ParseError $ T.pack err
            <> " while decoding " <> TE.decodeUtf8 (BL.toStrict msg')

-- | Eternally send data from libSends and usrSends channels
sendableLoop
    :: Connection
    -> VoiceWebsocketSendChan
    -> VoiceWebsocketSendChan
    -> Chan T.Text
    -> IO ()
sendableLoop conn libSends usrSends log = do
    -- Wait-time taken from discord-haskell/Internal.Gateway.EventLoop
    threadDelay $ round ((10^(6 :: Int)) * (62 / 120) :: Double)
    -- Get whichever possible, and send it
    payload <- either id id <$> race (readChan libSends) (readChan usrSends)
    log ✍ ("(send) " <> tshow payload) -- TODO: debug, remove.
    sendTextData conn $ encode payload
    sendableLoop conn libSends usrSends log

-- | Eternally send heartbeats through the libSends channel
heartbeatLoop
    :: VoiceWebsocketSendChan
    -> Int
    -- ^ milliseconds
    -> Chan T.Text
    -> IO ()
heartbeatLoop libSends interval log = do
    threadDelay $ 1 * 10^(6 :: Int)
    forever $ do
        time <- round <$> getPOSIXTime
        writeChan libSends $ Heartbeat $ time
        threadDelay $ interval * 1000

gatewayCheckerLoop
    :: Chan (Either GatewayException Event)
    -- ^ Gateway events
    -> MVar ()
    -- ^ Binary empty semaphore, set to () when gateway has reconnected
    -> Chan T.Text
    -- ^ log
    -> IO ()
gatewayCheckerLoop gatewayEvents sem log = do
    top <- readChan gatewayEvents
    log ✍ (tshow top)
    case top of
        Right (Discord.Internal.Types.Ready _ _ _ _ _) -> do
            log ✍ "gateway ready detected, putting () in sem"
            putMVar sem ()
            gatewayCheckerLoop gatewayEvents sem log
        _ -> gatewayCheckerLoop gatewayEvents sem log

-- | This function is the main event loop for the Websocket, after all initial
-- handshake stages (Hello and identification/resumption). It will continuously
-- read the top packet in the Websocket receives, and handle closures, and
-- packet responses (like heartbeat responses).
-- TODO: a separate ADT for this? what to call it
eventStream
    :: Connection
    -> WebsocketLaunchOpts
    -> Int
    -> UDPLaunchOpts
    -> VoiceWebsocketSendChan
    -> Chan T.Text
    -> IO WSState
eventStream conn opts interval udpLaunchOpts libSends log = do
    -- there has to be at least one packet every @interval@ milliseconds (which
    -- is the heartbeat response), so if we don't get that, it's a sign of
    -- the connection gone, we should reconnect. For a quick heuristic accounting
    -- for any network delays, allow for a tolerance of double the time.
    payload <- doOrTimeout (interval * 2) $ getPayload conn
    log ✍ ("(recv) " <> tshow payload) -- TODO: debug, remove.
    case payload of
        Nothing -> do
            log ✍! "connection timed out, trying to reconnect again."
            pure WSResume
        -- Network-WebSockets, type ConnectionException
        Just (Left (CloseRequest code str)) -> do
            -- Whether we resume or gracefully close depends on the close code,
            -- so offload the decision to the close code handler.
            handleClose code str
        Just (Left _) -> do
            log ✍! "connection exception in eventStream, trying to reconnect."
            pure WSResume
        Just (Right (HeartbeatAck _)) ->
            eventStream conn opts interval udpLaunchOpts libSends log
        Just (Right receivable) -> do
            writeChan (opts ^. wsHandle . _1) (Right receivable)
            eventStream conn opts interval udpLaunchOpts libSends log

  where
    -- | Handle Websocket Close codes by logging appropriate messages and
    -- closing the connection.
    handleClose :: Word16 -> BL.ByteString -> IO WSState
    handleClose 1000 str = log ✍! "websocket closed normally."
        >> pure WSClosed
    handleClose 4001 str = log ✍! "websocket closed due to unknown opcode"
        >> pure WSClosed
    handleClose 4014 str = log ✍! ("vc deleted, main gateway closed, or bot " <>
        "forcefully disconnected... Restarting voice.")
        >> pure WSStart
    handleClose 4015 str = log ✍! "server crashed on Discord side, resuming"
        >> pure WSResume
    handleClose code str = (✍!) log ("connection closed with code: [" <>
        tshow code <> "] " <> (TE.decodeUtf8 $ BL.toStrict str))
        >> pure WSClosed
