import Prelude hiding (catch)

import Network
import System.IO
import System.IO.Error (isEOFError)
import Control.Exception (finally, catch, Exception(..))
import qualified Data.ByteString.Lazy as BSL

kalxGet = "GET /kalx-128.mp3 HTTP/1.0\r\nHostname: icecast.media.berkeley.edu\r\nUser-Agent: eklitzke-haskell\r\n\r\n"

-- skip over the HTTP headers
skipResponseHeaders :: Handle -> IO ()
skipResponseHeaders hdl = do
    ln <- hGetLine hdl
    case ln of
        "\r" -> return ()
        _    -> skipResponseHeaders hdl

writeHTTPRequest :: Handle -> String -> IO ()
writeHTTPRequest sock s = do
    hPutStr sock s
    hFlush sock

main = do

    sock <- connectTo "icecast.media.berkeley.edu" $ PortNumber 8000
    writeHTTPRequest sock kalxGet
    skipResponseHeaders sock

    BSL.hGetContents sock >>= BSL.putStr
