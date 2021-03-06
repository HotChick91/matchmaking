module Matchmaking.Scraper (
    scraper,
    playersFromFile,
    extractPlayers,
) where

import Control.Monad
import Control.Concurrent
import Control.Exception
import Data.Char
import Data.IORef
import Data.List
import Data.Map ((!))
import Data.Maybe
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time
import Database.PostgreSQL.Simple
import Network.HTTP.Client
import Network.HTTP.Types
import System.IO
import System.IO.Unsafe
import Text.HTML.TagSoup
import qualified Data.ByteString.Char8 as SC
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as LC
import qualified Data.Map.Strict as M

import Matchmaking.Common
import Matchmaking.DB

usScrapeSleep :: Int
usScrapeSleep = 30 * 1000 * 1000

usErrorSleep :: Int
usErrorSleep = 100 * 1000 * 1000

scraper :: [Task] -> IO ()
scraper tasks = do
    manager <- newManager $ defaultManagerSettings { managerModifyRequest = addHeaders }
    forM_ tasks $ \task -> do
        putStrLn $ "scraping " ++ show task
        hFlush stdout
        catches (handleTask manager task)
            [ Handler $ \e -> putException (e :: ErrorCall)
            , Handler $ \e -> putException (e :: HttpException)
            , Handler $ \e -> pgException (e :: SqlError)
            , Handler $ \e -> pgException (e :: IOError)
            ]
        catches updateStats
            [ Handler $ \e -> pgException (e :: SqlError)
            , Handler $ \e -> pgException (e :: IOError)
            ]
        threadDelay usScrapeSleep
    where
    addHeaders r = return $ r
        { requestHeaders
            = (hAcceptLanguage, "en-US,en")
            : (hUserAgent, "Matchmaking/1.0 (+http://www.ismatchmakingfixedyet.com)")
            : requestHeaders r
        , cookieJar = Nothing
        }
    putException e = do
        putStrLn $ "scraper error'd: " ++ show e
        hFlush stdout
        threadDelay usErrorSleep
    pgException e = do
        putStrLn $ "pg error'd: " ++ show e
        hFlush stdout
        reconnect
    reconnect = do
        threadDelay usErrorSleep
        putStrLn "reconnecting to pg"
        hFlush stdout
        -- keep reconnecting until success
        handle (\e -> const reconnect (e :: IOError)) $ do
            connectPG
            putStrLn "pg reconnect successful"

handleTask :: Manager -> Task -> IO ()
handleTask _ (FetchGrandmasters _) = error "FetchGrandmasters unsupported"
handleTask manager (FetchMatch reg played hMatch) = do
    matchHtml <- fetchMatch manager hMatch
    let lastMatch = extractMatch hMatch reg played matchHtml
    insertMatch lastMatch
handleTask manager (FetchLastMatch gp) = do
    history <- fetchHistory manager gp
    handleMatch $ extractMatchId history 0
    savePersist $ cyclSucc gp
    where
    handleMatch (hMatch, played) = do
        present <- matchPresent hMatch
        unless present $ handleTask manager (FetchMatch (gpRegion gp) played hMatch)

playersFromFile :: Region -> String -> IO ()
playersFromFile reg fn = do
    players <- map read . lines <$> readFile fn
    updatePlayers reg players

-- all the extract* functions are very susceptible to changes in Hotslogs HTML
-- an API would be a godsend
extractPlayers :: L.ByteString -> [HotslogsPlayer]
extractPlayers = map shapeshift . sections rowPred . parseTags
    where
    rowPred tag =
        tag ~== ("<tr class='rgRow'>" :: String) ||
        tag ~== ("<tr class='rgAltRow'>" :: String)
    shapeshift = tt2integral . (!! 3)

stripParen :: L.ByteString -> L.ByteString
stripParen lbs
    | L.head lbs == 0x28 = L.tail lbs
    | otherwise = lbs

tt2integral :: Integral a => Tag L.ByteString -> a
tt2integral = fromInteger . fst . fromJust . LC.readInteger . stripParen . fromTagText

tts2integral :: Integral a => [Tag L.ByteString] -> a
tts2integral = tt2integral . head . filter isInt . filter isTagText

isInt :: Tag L.ByteString -> Bool
isInt tt = case LC.readInteger . stripParen . fromTagText $ tt of
    Nothing -> False
    Just (_, rest) -> not . LC.any isAlpha $ rest

tt2string :: Tag L.ByteString -> String
tt2string = LC.unpack . fromTagText

tts2string :: [Tag L.ByteString] -> String
tts2string = tt2string . head . dropWhile (not . isTagText)

tt2text :: Tag L.ByteString -> Text
tt2text = decodeUtf8 . L.toStrict . fromTagText

tts2text :: [Tag L.ByteString] -> Text
tts2text = tt2text . head . dropWhile (not . isTagText)

gms :: IORef Grandmasters
gms = unsafePerformIO $ newIORef mempty
{-# NOINLINE gms #-}

updatePlayers :: Region -> [HotslogsPlayer] -> IO ()
updatePlayers reg players = modifyIORef' gms $ insertMany $ zip regGPs players
    where
    regGPs = filter ((reg ==) . gpRegion) [minBound .. maxBound]
    insertMany [] tree = tree
    insertMany ((k, v) : kvs) tree = insertMany kvs $! M.insert k v tree

extractMatchId :: L.ByteString -> Int -> (HotslogsMatch, UTCTime)
extractMatchId lbs n = (tts2integral matchIdTags, tts2date dateTags)
    where
    skip = dropWhile (~/= ("<tr id='__" ++ show n ++ "'>"))
    matchIdTags = getCell 1 . skip . parseTags $ lbs
    dateTags = getCell 9 matchIdTags
    tts2date = fromJust . readHTime . tts2string

fetchHistory :: Manager -> GlobalPlace -> IO L.ByteString
fetchHistory manager gp = do
    hPlayer <- (! gp) <$> readIORef gms
    responseBody <$> httpLbs (request hPlayer) manager
    where
    request hPlayer = setQueryString
        [ ("PlayerID", Just $ SC.pack $ show hPlayer)
        ] "http://www.hotslogs.com/Player/MatchHistory"

extractMatch :: HotslogsMatch -> Region -> UTCTime -> L.ByteString -> Match
extractMatch hMatch reg played lbs = Match hMatch played mh ml nh nl reg
    where
    (mh, nh) = last players
    (ml, nl) = head players
    players = sort . map extractSingle $ rowTags
    entryPoint = dropWhile (~/= ("<td colspan='14'>" :: String)) . parseTags $ lbs
    allTags = sections (~== ("<td class='rgGroupCol'>" :: String)) entryPoint
    rowTags = take 5 allTags ++ take 5 (drop 6 allTags)
    extractSingle rowTag = (getHotdogs rowTag, getName rowTag)
    getName = tts2text . getCell 2
    getHotdogs = tts2integral . getCell 21

getCell :: Int -> [Tag L.ByteString] -> [Tag L.ByteString]
getCell 0 = dropWhile (~/= ("<td>" :: String))
getCell n = getCell (n - 1) . tail . getCell 0

fetchMatch :: Manager -> HotslogsMatch -> IO L.ByteString
fetchMatch manager hMatch = responseBody <$> httpLbs request manager
    where
    request = setQueryString
        [ ("ReplayID", Just $ SC.pack $ show hMatch)
        ] "http://www.hotslogs.com/Player/MatchSummaryAjax"
