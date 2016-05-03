module Matchmaking.Scraper (scraper) where

import Control.Monad
import Control.Concurrent
import Control.Exception
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
import System.IO.Unsafe
import Text.HTML.TagSoup
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as SC
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as LC
import qualified Data.Map.Strict as M

import Matchmaking.Common
import Matchmaking.DB

scraper :: Connection -> [Task] -> IO ()
scraper conn tasks = do
    manager <- newManager $ defaultManagerSettings { managerModifyRequest = addHeaders }
    forM_ tasks $ \task -> do
        putStrLn $ "scraping! " ++ show task
        gms' <- readIORef gms
        putStrLn $ "gms: " ++ show (M.size gms')
        catches (handleTask manager conn task)
            [ Handler $ \e -> putException (e :: ErrorCall)
            , Handler $ \e -> putException (e :: HttpException)
            , Handler $ \e -> putException (e :: SqlError)
            ]
        catch (updateStats conn) $ \e -> putException (e :: SqlError)
        threadDelay $ 60 * 1000 * 1000
    where
    addHeaders r = return $ r
        { requestHeaders
            = (hAcceptLanguage, "en-US,en")
            : (hUserAgent, "Matchmaking/1.0 (+http://www.ismatchmakingfixedyet.com)")
            : requestHeaders r
        , cookieJar = Nothing
        }
    putException e = putStrLn $ "updateStats error'd: " ++ show e

handleTask :: Manager -> Connection -> Task -> IO ()
handleTask manager _ (FetchGrandmasters reg) = do
    players <- extractPlayers <$> fetchLeaderboard manager reg
    putStrLn $ show players
    updatePlayers reg players
handleTask manager conn (FetchLastMatch gp) = do
    (lastMatchId, played) <- extractMatchId <$> fetchHistory manager gp
    putStrLn $ "match id " ++ show (lastMatchId, played)
    present <- matchPresent conn lastMatchId
    putStrLn $ "present " ++ show present
    unless present $ handleTask manager conn (FetchMatch (gpRegion gp) played lastMatchId)
handleTask manager conn (FetchMatch reg played hMatch) = do
    matchHtml <- fetchMatch manager hMatch
    let lastMatch = extractMatch hMatch reg played matchHtml
    putStrLn $ "match " ++ show hMatch
    insertMatch conn lastMatch

-- all the extract* functions are very susceptible to changes in Hotslogs HTML
-- an API would be a godsend
extractPlayers :: L.ByteString -> [HotslogsPlayer]
extractPlayers = map shapeshift . sections rowPred . parseTags
    where
    rowPred tag =
        tag ~== ("<tr class='rgRow'>" :: String) ||
        tag ~== ("<tr class='rgAltRow'>" :: String)
    shapeshift = tt2integral . head . drop 3

reg2hreg :: Region -> S.ByteString
reg2hreg NA = "1"
reg2hreg EU = "2"

stripParen :: L.ByteString -> L.ByteString
stripParen lbs
    | L.head lbs == 0x28 = L.tail lbs
    | otherwise = lbs

tt2integral :: Integral a => Tag L.ByteString -> a
tt2integral = fromInteger . fst . fromJust . LC.readInteger . stripParen . fromTagText

tt2string :: Tag L.ByteString -> String
tt2string = LC.unpack . fromTagText

tt2text :: Tag L.ByteString -> Text
tt2text = decodeUtf8 . L.toStrict . fromTagText

fetchLeaderboard :: Manager -> Region -> IO L.ByteString
fetchLeaderboard manager reg = responseBody <$> httpLbs request manager
    where
    request = setQueryString
        [ ("Region", Just $ reg2hreg reg)
        , ("GameMode", Just "4")
        , ("League", Just "Master")
        ] "http://www.hotslogs.com/Rankings"

gms :: IORef Grandmasters
gms = unsafePerformIO $ newIORef mempty
{-# NOINLINE gms #-}

updatePlayers :: Region -> [HotslogsPlayer] -> IO ()
updatePlayers reg players = modifyIORef' gms $ insertMany $ zip regGPs players
    where
    regGPs = filter ((reg ==) . gpRegion) [minBound .. maxBound]
    insertMany [] tree = tree
    insertMany ((k, v) : kvs) tree = insertMany kvs $! M.insert k v tree

extractMatchId :: L.ByteString -> (HotslogsMatch, UTCTime)
extractMatchId lbs = (tt2integral $ head matchIdTags, tt2date $ head dateTags)
    where
    skip = dropWhile (~/= ("<tr id='__0'>" :: String))
    matchIdTags = drop 6 . skip . parseTags $ lbs
    dateTags = drop 29 matchIdTags
    tt2date = fromJust . readHTime . tt2string

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
    entryPoint = dropWhile (~/= ("<td colspan='13'>" :: String)) . parseTags $ lbs
    allTags = sections (~== ("<td class='rgGroupCol'>" :: String)) $ entryPoint
    rowTags = take 5 allTags ++ take 5 (drop 6 allTags)
    extractSingle rowTag = (tt2integral $ getHotdogs rowTag, tt2text $ getName rowTag)
    getName = head . dropWhile (not . isTagText) . drop 4
    getHotdogs = head . filter isInt . filter isTagText . drop 20
    isInt = isJust . LC.readInteger . stripParen . fromTagText

fetchMatch :: Manager -> HotslogsMatch -> IO L.ByteString
fetchMatch manager hMatch = responseBody <$> httpLbs request manager
    where
    request = setQueryString
        [ ("ReplayID", Just $ SC.pack $ show hMatch)
        ] "http://www.hotslogs.com/Player/MatchSummaryAjax"