module Hyper.Deprecated.RecordBasedRouter
       ( Path
       , pathToHtml
       , pathFromString
       , Supported
       , Unsupported
       , ResourceMethod
       , handler
       , notSupported
       , resource
       , ResourceRecord
       , router
       , ResourceRouter()
       , runRouter
       , defaultRouterFallbacks
       , linkTo
       , formTo
       ) where

import Prelude
import Control.Alt (class Alt)
import Data.Array (filter)
import Data.Leibniz (type (~))
import Data.Maybe (Maybe(Just, Nothing))
import Data.String (Pattern(Pattern), split, joinWith)
import Data.Tuple (Tuple(Tuple))
import Hyper.Core (class ResponseWriter, ResponseEnded, StatusLineOpen, writeStatus, Middleware, Conn)
import Hyper.HTML (form, a, HTML)
import Hyper.Method (Method(..))
import Hyper.Response (class Response, respond, headers)
import Hyper.Status (statusMethodNotAllowed, statusNotFound)

type Path = Array String

pathToHtml :: Path -> String
pathToHtml = (<>) "/" <<< joinWith "/"

pathFromString :: String -> Path
pathFromString = filter ((/=) "") <<< split (Pattern "/")

data Supported = Supported
data Unsupported = Unsupported

data ResourceMethod r m x y
  = Routed (Middleware m x y) r (r ~ Supported)
  | NotRouted r (r ~ Unsupported)

handler :: forall m req req' res res' c c'.
           Middleware m (Conn req res c) (Conn req' res' c')
           -> ResourceMethod Supported m (Conn req res c) (Conn req' res' c')
handler mw = Routed mw Supported id

notSupported :: forall e req res c req' res' c'.
                ResourceMethod Unsupported e (Conn req res c) (Conn req' res' c')
notSupported = NotRouted Unsupported id

methodHandler :: forall m e x y.
                 ResourceMethod m e x y
                 -> Maybe (Middleware e x y)
methodHandler (Routed mw _ _) = Just mw
methodHandler (NotRouted _ _) = Nothing

data RoutingResult c
  = RouteMatch c
  | NotAllowed Method
  | NotFound

instance functorRoutingResult :: Functor RoutingResult where
  map f =
    case _ of
      RouteMatch c -> RouteMatch (f c)
      NotAllowed method -> NotAllowed method
      NotFound -> NotFound

newtype ResourceRouter m c c' = ResourceRouter (Middleware m c (RoutingResult c'))

instance functorResourceRouter :: Functor m => Functor (ResourceRouter m c) where
  map f (ResourceRouter r) = ResourceRouter $ \conn -> map (map f) (r conn)

instance altResourceRouter :: Monad m => Alt (ResourceRouter m c) where
  -- NOTE: We have strict evaluation, and we only want to run 'g' if 'f'
  -- resulted in a `NotFound`.
  alt (ResourceRouter f) (ResourceRouter g) = ResourceRouter $ \conn -> do
    result <- f conn
    case result of
      RouteMatch conn' -> pure (RouteMatch conn')
      NotAllowed method -> pure (NotAllowed method)
      NotFound -> g conn

type ResourceRecord m options get head post put patch delete trace connect c c' =
  { path :: Path
  , "OPTIONS" :: ResourceMethod options m c c'
  , "GET" :: ResourceMethod get m c c'
  , "HEAD" :: ResourceMethod head m c c'
  , "POST" :: ResourceMethod post m c c'
  , "PUT" :: ResourceMethod put m c c'
  , "PATCH" :: ResourceMethod patch m c c'
  , "DELETE" :: ResourceMethod delete m c c'
  , "TRACE" :: ResourceMethod trace m c c'
  , "CONNECT" :: ResourceMethod connect m c c'
  }

resource
  :: forall m req res c req' res' c'.
     { path :: Unit
     , "OPTIONS" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "GET" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "HEAD" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "POST" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "PUT" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "PATCH" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "DELETE" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "TRACE" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     , "CONNECT" :: ResourceMethod Unsupported m (Conn req res c) (Conn req' res' c')
     }
resource =
  { path: unit
  , "OPTIONS": notSupported
  , "GET": notSupported
  , "HEAD": notSupported
  , "POST": notSupported
  , "PUT": notSupported
  , "PATCH": notSupported
  , "DELETE": notSupported
  , "TRACE": notSupported
  , "CONNECT": notSupported
  }

router
  :: forall options get head post put patch delete trace connect m req res c req' res' c'.
     Applicative m =>
     ResourceRecord
     m
     options
     get
     head
     post
     put
     patch
     delete
     trace
     connect
     (Conn { url :: String, method :: Method | req } res c)
     (Conn { url :: String, method :: Method | req' } res' c')
  -> ResourceRouter
     m
     (Conn { url :: String, method :: Method | req } res c)
     (Conn { url :: String, method :: Method | req' } res' c')
router r =
  ResourceRouter result
  where
    handler' conn =
      case conn.request.method of
        OPTIONS -> methodHandler r."OPTIONS"
        GET -> methodHandler r."GET"
        HEAD -> methodHandler r."HEAD"
        POST -> methodHandler r."POST"
        PUT -> methodHandler r."PUT"
        PATCH -> methodHandler r."PATCH"
        DELETE -> methodHandler r."DELETE"
        TRACE -> methodHandler r."TRACE"
        CONNECT -> methodHandler r."CONNECT"
    result conn =
      if r.path == pathFromString conn.request.url
      then case handler' conn of
        Just mw -> RouteMatch <$> mw conn
        Nothing -> pure (NotAllowed conn.request.method)
      else pure NotFound

type RouterFallbacks m c c' =
  { onNotFound :: Middleware m c c'
  , onMethodNotAllowed :: Method -> Middleware m c c'
  }

defaultRouterFallbacks
  :: forall m rw b req res c.
     (Monad m, Response b m String, ResponseWriter rw m b) =>
     RouterFallbacks
     m
     (Conn req { writer :: rw StatusLineOpen | res } c)
     (Conn req { writer :: rw ResponseEnded | res } c)
defaultRouterFallbacks =
  { onNotFound:
    writeStatus statusNotFound
    >=> headers []
    >=> respond "Not Found"
  , onMethodNotAllowed:
    \method ->
    writeStatus statusMethodNotAllowed
    >=> headers []
    >=> respond ("Method " <> show method <> " not allowed.")
  }

runRouter
  :: forall m c c'.
     Monad m =>
     RouterFallbacks m c c'
     -> ResourceRouter m c c'
     -> Middleware m c c'
runRouter fallbacks (ResourceRouter rr) conn = do
  result <- rr conn
  case result of
    RouteMatch conn' -> pure conn'
    NotAllowed method -> fallbacks.onMethodNotAllowed method conn
    NotFound -> fallbacks.onNotFound conn

linkTo :: forall m c c' ms.
          { path :: Path
          , "GET" :: ResourceMethod Supported m c c'
          | ms }
          -> Array HTML
          -> HTML
linkTo resource' nested = do
  a [Tuple "href" (pathToHtml resource'.path)] nested

formTo :: forall m c c' ms.
          { path :: Path
          , "POST" :: ResourceMethod Supported m c c'
          | ms
          }
          -> Array HTML
          -> HTML
formTo resource' nested =
  form
  [ Tuple "method" "post"
  , Tuple "action" (pathToHtml resource'.path)
  ]
  nested
