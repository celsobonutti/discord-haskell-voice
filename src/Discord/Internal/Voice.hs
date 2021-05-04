module Discord.Internal.Voice
    ( joinVoice
    ) where

import           Control.Concurrent.Async           ( race
                                                    )
import           Control.Concurrent                 ( ThreadId
                                                    , threadDelay
                                                    , forkIO
                                                    , Chan
                                                    , dupChan
                                                    , newChan
                                                    , readChan
                                                    , writeChan
                                                    , newEmptyMVar
                                                    , readMVar
                                                    , putMVar
                                                    )
import           Control.Exception.Safe             ( SomeException
                                                    , handle
                                                    )
import           Control.Monad.Reader               ( ask
                                                    , liftIO
                                                    )
import           Data.Aeson
import           Data.Aeson.Types                   ( parseMaybe
                                                    , parseEither
                                                    )
import           Data.Maybe                         ( fromJust
                                                    )
import qualified Data.Text as T

import           Discord.Internal.Types             ( GuildId
                                                    , ChannelId
                                                    , Event
                                                    , GatewaySendable(..)
                                                    , UpdateStatusVoiceOpts
                                                    )
import           Discord.Internal.Voice.WebsocketLoop
import           Discord.Internal.Voice.UDPLoop
import           Discord.Internal.Types.VoiceWebsocket
import           Discord.Internal.Types.VoiceUDP
import           Discord.Internal.Types             ( GuildId
                                                    , UserId
                                                    , User(..)
                                                    , UpdateStatusVoiceOpts(..)
                                                    , Event( UnknownEvent )
                                                    )
import           Discord.Internal.Gateway.EventLoop
                                                    ( GatewayException(..)
                                                    )
import           Discord.Internal.Gateway.Cache     ( Cache(..)
                                                    )
import           Discord.Handle                     ( discordHandleGateway
                                                    , discordHandleLog
                                                    , discordHandleCache
                                                    )
import           Discord                            ( DiscordHandler
                                                    , sendCommand
                                                    )

data DiscordVoiceThreadId
    = DiscordVoiceThreadIdWebsocket ThreadId
    | DiscordVoiceThreadIdUDP ThreadId

data DiscordVoiceHandle = DiscordVoiceHandle
    { discordVoiceHandleWebsocket   :: DiscordVoiceHandleWebsocket
    , discordVoiceHandleUDP         :: DiscordVoiceHandleUDP
    , discordVoiceThreads           :: [DiscordVoiceThreadId]
    }

-- | Joins a voice channel and initialises all the threads, ready to stream.
joinVoice
    :: GuildId
    -> ChannelId
    -> Bool
    -> Bool
    -> DiscordHandler (Maybe DiscordVoiceHandle)
joinVoice gid cid mute deaf = do
    -- Duplicate the event channel, so we can read without taking data from event handlers
    h <- ask
    let (_events, _, _) = discordHandleGateway h
    events <- liftIO $ dupChan _events
    
    -- Send opcode 4
    sendCommand $ UpdateStatusVoice $ UpdateStatusVoiceOpts
        { updateStatusVoiceOptsGuildId = gid
        , updateStatusVoiceOptsChannelId = Just cid
        , updateStatusVoiceOptsIsMuted = mute
        , updateStatusVoiceOptsIsDeaf = deaf
        }

    -- Wait for Opcode 0 Voice State Update and Voice Server Update
    -- for a maximum of 5 seconds
    result <- liftIO $ loopUntilEvents events

    case result of
        Nothing -> do
            liftIO $ writeChan (discordHandleLog h) $
                "Discord did not respond to opcode 4 in time. " <>
                    "Perhaps it may not have permission to join."
            pure Nothing
        Just (_, _, _, Nothing) -> do
            -- If endpoint is null, according to Docs, no servers are available.
            liftIO $ writeChan (discordHandleLog h) $
                "Discord did not give a good endpoint. " <>
                    "Perhaps it is down for maintenance."
            pure Nothing
        Just (sessionId, token, guildId, Just endpoint) -> do
            let connInfo = WSConnInfo
                    { wsInfoSessionId = sessionId
                    , wsInfoToken     = token
                    , wsInfoGuildId   = guildId
                    , wsInfoEndpoint  = endpoint
                    }
            -- Get the current user ID, and pass it on with all the other data
            eCache <- liftIO $ readMVar $ snd $ discordHandleCache h 
            case eCache of
                Left _ -> do
                    liftIO $ writeChan (discordHandleLog h)
                        "Could not get current user from cache."
                    pure Nothing
                Right cache -> do
                    let uid = userId $ _currentUser cache
                    liftIO $ startVoiceThreads connInfo uid $ discordHandleLog h
                    

-- | Loop a maximum of 5 seconds, or until both Voice State Update and
-- Voice Server Update has been received.
loopUntilEvents
    :: Chan (Either GatewayException Event)
    -> IO (Maybe (T.Text, T.Text, GuildId, Maybe T.Text))
loopUntilEvents events = eitherRight <$> race wait5 (waitForBoth Nothing Nothing)
  where
    wait5 :: IO ()
    wait5 = threadDelay (5 * 10^(6 :: Int))

    -- | Wait for both VOICE_STATE_UPDATE and VOICE_SERVER_UPDATE.
    -- The order is undefined in docs.
    waitForBoth
        :: Maybe T.Text
        -> Maybe (T.Text, GuildId, Maybe T.Text)
        -> IO (T.Text, T.Text, GuildId, Maybe T.Text)
    waitForBoth (Just a) (Just (b, c, d)) = pure (a, b, c, d)
    waitForBoth mb1 mb2 = do
        top <- readChan events
        case top of
            Right (UnknownEvent "VOICE_STATE_UPDATE" obj) -> do
                -- Parse the unknown event, and call waitForVoiceServer
                -- We assume "d -> session_id" always exists because Discord
                -- said so.
                let sessionId = flip parseMaybe obj $ \o -> do
                        o .: "session_id"
                waitForBoth sessionId mb2
            Right (UnknownEvent "VOICE_SERVER_UPDATE" obj) -> do
                let result = flip parseMaybe obj $ \o -> do
                        token <- o .: "token"
                        guildId <- o .: "guild_id"
                        endpoint <- o .: "endpoint"
                        pure (token, guildId, endpoint)
                waitForBoth mb1 result
            Right _ -> waitForBoth mb1 mb2
            Left _  -> waitForBoth mb1 mb2

-- | Selects the right element as a Maybe
eitherRight :: Either a b -> Maybe b
eitherRight (Left _)  = Nothing
eitherRight (Right x) = Just x

-- | Start the Websocket thread, which will create the UDP thread
startVoiceThreads
    :: WebsocketConnInfo
    -> UserId
    -> Chan T.Text
    -> IO (Maybe DiscordVoiceHandle)
startVoiceThreads connInfo uid log = do
    -- First create the websocket (which will automatically try to identify)
    events <- newChan -- types are inferred from line below
    sends <- newChan
    syncKey <- newEmptyMVar
    websocketId <- forkIO $ voiceWebsocketLoop (events, sends) (connInfo, uid) log
    
    -- The first event is either a Right (Ready payload) or Left errors
    e <- readChan events
    case e of
        Right (Ready p) -> do
            -- Now try to create the UDP thread
            let udpInfo = UDPConnInfo
                    { udpInfoSSRC = readyPayloadSSRC p
                    , udpInfoAddr = readyPayloadIP p
                    , udpInfoPort = readyPayloadPort p
                    , udpInfoMode = "xsalsa20_poly1305"
                    -- ^ Too much hassle to implement all encryption modes.
                    }
            
            byteReceives <- newChan
            byteSends <- newChan
            udpId <- forkIO $ udpLoop (byteReceives, byteSends) udpInfo syncKey log

            -- the first packet is a IP Discovery response.
            (IPDiscovery _ ip port) <- readChan byteReceives
            
            -- signal to the voice websocket using Opcode 1 Select Protocol
            writeChan sends $ SelectProtocol $ SelectProtocolPayload
                { selectProtocolPayloadProtocol = "udp"
                , selectProtocolPayloadIP       = ip
                , selectProtocolPayloadPort     = port
                , selectProtocolPayloadMode     = "xsalsa20_poly1305"
                }

            -- the next thing we receive in the websocket *should* be an
            -- Opcode 4 Session Description
            f <- readChan events
            case f of
                Right (SessionDescription _ key) -> do
                    putMVar syncKey key
                    pure $ Just $ DiscordVoiceHandle
                        { discordVoiceHandleWebsocket = (events, sends)
                        , discordVoiceHandleUDP       = (byteReceives, byteSends)
                        , discordVoiceThreads         =
                            [ DiscordVoiceThreadIdWebsocket websocketId
                            , DiscordVoiceThreadIdUDP udpId
                            ]
                        }
                Right _ -> pure Nothing
                Left  _ -> pure Nothing
        Right _ -> pure Nothing
        Left  _ -> pure Nothing

