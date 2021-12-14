{-# LANGUAGE ImportQualifiedPost #-}
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
    , ThreadId
    )
import Control.Exception.Safe ( try, SomeException, finally, handle )
import Control.Monad ( forever )
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
import Discord.Internal.Gateway ( GatewayException )
import Discord.Internal.Types ( GuildId, UserId, Event(..) )
import Discord.Internal.Types.VoiceCommon
import Discord.Internal.Types.VoiceWebsocket


data WSLoopState
    = WSStart
    | WSClosed
    | WSResume
    deriving Show

wsError :: T.Text -> T.Text
wsError t = "Voice Websocket error - " <> t

connect :: T.Text -> (Connection -> IO a) -> IO a
connect endpoint = runSecureClient url port "/"
  where
    url = (T.unpack . T.takeWhile (/= ':')) endpoint
    port = (read . T.unpack . T.takeWhileEnd (/= ':')) endpoint

-- | Attempt to connect (and reconnect on disconnects) to the voice websocket.
-- Also launches the UDP thread after the initialisation.
launchWebsocket
    :: WebsocketConnInfo
    -- ^ The connection info (session_id, token, guild_id, endpoint) for the
    -- voice websocket.
    -> Chan (Either GatewayException Event)
    -- ^ The duplicated channel where main gateway events are added to. This
    -- function is the only one that should ever take from this channel.
    -> DiscordVoiceHandleWebsocket
    -- ^ The tuple of received data and sending data channels for the websocket.
    -> (MVar ThreadId, MVar DiscordVoiceHandleUDP)
    -- ^ An MVar tuple containing the thread ID of the UDP loop receive/send
    -- Chans, to report back to startThreads in Voice.hs.
    -> Chan T.Text
    -> IO ()
launchWebsocket info gatewayEvents (receives, sends) (udpTidM, udpHandleM) log = loop WSStart 0
  where
    loop :: WSLoopState -> Int -> IO ()
    loop s retries = do
        case s of
            WSClosed -> pure ()
            -- Legitimate closure. We're done.
            WSStart -> do
                -- First-timer. Open a Websocket connection, do all the routine,
                -- then create the UDP thread (fill in the MVars to report back
                -- immediately upon creation, so it can be killed if any errors
                -- happen down the line).
                next <- try $ connect (wsInfoEndpoint info) $ \conn -> do
                    -- Send opcode 0 Identify
                    sendTextData conn $ encode $ Identify $ IdentifyPayload
                        { identifyPayloadServerId = wsInfoGuildId info
                        , identifyPayloadUserId = undefined
                        , identifyPayloadSessionId = wsInfoSessionId info
                        , identifyPayloadToken = wsInfoToken info
                        }
                    -- Attempt to get opcode 2 Ready and Opcode 8 Hello in an
                    -- undefined order.
                    result <- waitForHelloReadyOr10Seconds conn
                    case result of
                        Nothing -> do
                            writeChan log $ wsError $
                                "did not receive a valid Opcode 2 and 8 " <>
                                    "after connection within 10 seconds"
                            pure WSClosed
                        Just (interval, payload) -> do
                            -- All good! Start the heartbeating and send loops.
                            writeChan receives $ Right (Discord.Internal.Types.VoiceWebsocket.Ready payload)
                            startEternalStream (WSConn conn info receives)
                                gatewayEvents interval sends log
                -- Connection is now closed.
                case next :: Either SomeException WSLoopState of
                    Left e -> do
                        writeChan log $ wsError $
                            "could not connect due to an exception: " <>
                                (T.pack $ show e)
                        writeChan receives $ Left $
                            VoiceWebsocketCouldNotConnect
                                "could not connect due to an exception"
                        loop WSClosed 0
                    Right n -> loop n 0

            WSResume -> do
                next <- try $ connect (wsInfoEndpoint info) $ \conn -> do
                    -- Send opcode 7 Resume
                    sendTextData conn $ encode $
                        Resume (wsInfoGuildId info) (wsInfoSessionId info) (wsInfoToken info)
                    -- Attempt to get opcode 9 Resumed and Opcode 8 Hello in an
                    -- undefined order
                    result <- waitForHelloResumedOr10Seconds conn
                    case result of
                        Nothing -> do
                            writeChan log $ wsError $
                                "did not receive a valid Opcode 9 and 8 " <>
                                    "after reconnection within 10 seconds"
                            pure WSStart
                        Just interval -> do
                            startEternalStream (WSConn conn info receives)
                                gatewayEvents interval sends log
                -- Connection is now closed.
                case next :: Either SomeException WSLoopState of
                    Left _ -> do
                        writeChan log $ wsError
                            "could not resume, retrying after 10 seconds"
                        threadDelay $ 10 * (10^(6 :: Int))
                        loop WSResume (retries + 1)
                    Right n -> loop n 1

    -- | Wait for 10 seconds or received Ready and Hello, whichever comes first.
    -- Discord Docs does not specify the order in which Ready and Hello can
    -- arrive, hence the complicated recursive logic and racing.
    waitForHelloReadyOr10Seconds :: Connection -> IO (Maybe (Int, ReadyPayload))
    waitForHelloReadyOr10Seconds conn =
        either id id <$> race wait10Seconds (waitForHelloReady conn Nothing Nothing)

    -- | Wait 11 seconds, this is for fallback when Discord never sends the msgs
    -- to prevent deadlocking. Type signature is generic to accommodate any
    -- kind of response (both for Resumed and Ready)
    wait10Seconds :: IO (Maybe a)
    wait10Seconds = do
        threadDelay $ 10 * 10^(6 :: Int)
        pure $ Nothing

    -- | Wait for both Opcode 2 Ready and Opcode 8 Hello, and return both
    -- responses in a Maybe (so that the type signature matches wait10seconds)
    waitForHelloReady
        :: Connection
        -> Maybe Int
        -> Maybe ReadyPayload
        -> IO (Maybe (Int, ReadyPayload))
    waitForHelloReady conn (Just x) (Just y) = pure $ Just (x, y)
    waitForHelloReady conn mb1 mb2 = do
        msg <- getPayload conn log
        print msg
        case msg of
            Right (Discord.Internal.Types.VoiceWebsocket.Ready payload) ->
                waitForHelloReady conn mb1 (Just payload)
            Right (Discord.Internal.Types.VoiceWebsocket.Hello interval) ->
                waitForHelloReady conn (Just interval) mb2
            Right _ ->
                waitForHelloReady conn mb1 mb2
            Left ConnectionClosed ->
                pure Nothing
            Left _  ->
                waitForHelloReady conn mb1 mb2

    -- | Wait for 10 seconds or received Resumed and Hello, whichever comes first.
    -- Discrod Docs does not specify the order here again, and does not even
    -- specify that Hello will be sent. Anyway, Hello sometimes comes before
    -- Resumed (as I've found out) so the logic is identical to
    -- waitForHelloReadyor10Seconds.
    waitForHelloResumedOr10Seconds :: Connection -> IO (Maybe Int)
    waitForHelloResumedOr10Seconds conn =
        either id id <$> race wait10Seconds (waitForHelloResumed conn Nothing False)

    -- | Wait for both Opcode 9 Resumed and Opcode 8 Hello, and return the
    -- Hello interval. There is no body in Resumed.
    waitForHelloResumed
        :: Connection
        -> Maybe Int
        -> Bool
        -> IO (Maybe Int)
    waitForHelloResumed conn (Just x) True = pure $ Just x
    waitForHelloResumed conn mb1 bool = do
        msg <- getPayload conn log
        case msg of
            Right (Discord.Internal.Types.VoiceWebsocket.Hello interval) ->
                waitForHelloResumed conn (Just interval) bool
            Right Discord.Internal.Types.VoiceWebsocket.Resumed ->
                waitForHelloResumed conn mb1 True
            Right _ ->
                waitForHelloResumed conn mb1 bool
            Left _ ->
                waitForHelloResumed conn mb1 bool

    -- userId :: IO UserId
    -- userId = (lift . lift) getCacheUserId
    -- log <- discordHandleLog <$> (lift . lift) ask

getPayload
    :: Connection
    -> Chan T.Text
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
getPayload conn log = try $ do
    msg' <- receiveData conn
    case eitherDecode msg' of
        Right msg -> pure msg
        Left err  -> do
            writeChan log $ "Voice Websocket parse error - " <> T.pack err
                <> " while decoding " <> TE.decodeUtf8 (BL.toStrict msg')
            pure $ ParseError $ T.pack err

getPayloadTimeout
    :: Connection
    -> Int
    -> Chan T.Text
    -> IO (Either ConnectionException VoiceWebsocketReceivable)
getPayloadTimeout conn interval log = do
  res <- race (threadDelay ((interval * 1000 * 3) `div` 2))
              (getPayload conn log)
  case res of
    Left () -> pure (Right Reconnect)
    Right other -> pure other

-- | Create the sendable and heartbeat loops.
startEternalStream
    :: WebsocketConn
    -> Chan (Either GatewayException Event)
    -- ^ gateway events
    -> Int
    -> Chan VoiceWebsocketSendable
    -> Chan T.Text
    -> IO WSLoopState
startEternalStream wsconn gatewayEvents interval sends log = do
    let err :: SomeException -> IO WSLoopState
        err e = do
            writeChan log $ wsError $ "event stream error: " <> T.pack (show e)
            pure WSResume
    handle err $ do
        sysSends <- newChan -- Chan for Heartbeat
        sendLoopId <- forkIO $ sendableLoop wsconn sysSends sends
        heartLoopId <- forkIO $ heartbeatLoop wsconn sysSends interval log
        gatewayReconnected <- newEmptyMVar
        gatewayCheckerId <- forkIO $ gatewayCheckerLoop gatewayEvents gatewayReconnected log

        finally (eventStream wsconn gatewayReconnected interval sysSends log) $
            (killThread heartLoopId >> killThread sendLoopId >> killThread gatewayCheckerId)

-- | Eternally stay on lookout for the connection. Writes to receivables channel.
eventStream
    :: WebsocketConn
    -> MVar ()
    -- ^ flag with () if gateway has reconnected
    -> Int
    -> Chan VoiceWebsocketSendable
    -> Chan T.Text
    -> IO WSLoopState
eventStream wsconn gatewayReconnected interval sysSends log = do
    sem <- tryReadMVar gatewayReconnected
    case sem of
        Just () -> do
            writeChan log $ wsError "gateway reconnected, doing same for voice."
            sendClose (wsDataConnection wsconn) $ T.pack "Hey Discord, we're reconnecting in a bit."
            pure WSResume
        Nothing -> do
            eitherPayload <- getPayloadTimeout (wsDataConnection wsconn) interval log
            putStrLn $ "<-- " <> show eitherPayload
            case eitherPayload of
                -- Network-WebSockets, type ConnectionException
                Left (CloseRequest code str) -> do
                    handleClose code str
                Left _ -> do
                    writeChan log $ wsError
                        "connection exception in eventStream."
                    pure WSResume
                Right Reconnect -> do
                    writeChan log $ wsError
                        "connection timed out, trying to reconnect again."
                    pure WSResume
                Right (HeartbeatAckR _) ->
                    -- discord docs says HeartbeatAck is sent (opcode 6) after every
                    -- Heartbeat (3) that I send. However, this doesn't seem to be
                    -- the case, as discord responds with another Heartbeat (3) to
                    -- my own, and Ack is never sent back.
                    -- I am required to send back an Ack from MY side in response to
                    -- the Heartbeat that they send which is in response to the
                    -- heartbeat that I send. wtf?
                    eventStream wsconn gatewayReconnected interval sysSends log
                Right (HeartbeatR a) -> do
                    writeChan sysSends $ HeartbeatAck a
                    eventStream wsconn gatewayReconnected interval sysSends log
                Right receivable -> do
                    writeChan (wsDataReceivesChan wsconn) (Right receivable)
                    eventStream wsconn gatewayReconnected interval sysSends log

  where
    -- | Handle Websocket Close codes by logging appropriate messages and
    -- closing the connection.
    handleClose :: Word16 -> BL.ByteString -> IO WSLoopState
    handleClose code str = do
        let reason = TE.decodeUtf8 $ BL.toStrict str
        case code of
            -- from discord.py voice_client.py#L421
            1000 -> do
                -- Normal close
                writeChan log $ wsError $
                    "websocket closed normally."
                pure WSClosed
            4001 -> do
                -- Unknown opcode
                writeChan log $ wsError $
                    "websocket closed due to unknown opcode"
                pure WSClosed
            4014 -> do
                -- VC deleted, main gateway closed, or bot kicked. Do not resume.
                -- Instead, restart from zero.
                writeChan log $ wsError $
                    "vc deleted or bot forcefully disconnected... Restarting gateway"
                pure WSStart
            4015 -> do
                -- "The server crashed. Our bad! Try resuming."
                pure WSResume
            x    -> do
                writeChan log $ wsError $
                    "connection closed with code: [" <> T.pack (show code) <>
                        "] " <> reason
                pure WSClosed


-- | Eternally send data from sysSends and usrSends channels
sendableLoop
    :: WebsocketConn
    -> Chan VoiceWebsocketSendable
    -> Chan VoiceWebsocketSendable
    -> IO ()
sendableLoop wsconn sysSends usrSends = do
    -- Wait-time taken from discord-haskell/Internal.Gateway.EventLoop
    threadDelay $ round ((10^(6 :: Int)) * (62 / 120) :: Double)
    -- Get whichever possible, and send it
    payload <- either id id <$> race (readChan sysSends) (readChan usrSends)
    print $ "--> " <> show payload
    sendTextData (wsDataConnection wsconn) $ encode payload
    sendableLoop wsconn sysSends usrSends

-- | Eternally send heartbeats through the sysSends channel
heartbeatLoop
    :: WebsocketConn
    -> Chan VoiceWebsocketSendable
    -> Int
    -- ^ milliseconds
    -> Chan T.Text
    -> IO ()
heartbeatLoop wsconn sysSends interval log = do
    threadDelay $ 1 * 10^(6 :: Int)
    forever $ do
        time <- round <$> getPOSIXTime
        writeChan sysSends $ Heartbeat $ time
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
    print top
    case top of
        Right (Discord.Internal.Types.Ready _ _ _ _ _) -> do
            writeChan log "gateway ready detected, putting () in sem"
            putMVar sem ()
            gatewayCheckerLoop gatewayEvents sem log
        _ -> gatewayCheckerLoop gatewayEvents sem log
