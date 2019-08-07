module Hyper.Response where

import Prelude

import Control.Monad.Indexed ((:>>=), (:*>))
import Data.Foldable (class Foldable, traverse_)
import Data.MediaType (MediaType)
import Data.Newtype (unwrap)
import Data.Tuple (Tuple(Tuple))
import Hyper.Conn (kind ResponseState, StatusLineOpen, HeadersOpen, BodyOpen, ResponseEnded, Conn)
import Hyper.Header (Header)
import Hyper.Middleware (Middleware)
import Hyper.Status (Status, statusFound)

-- | A middleware transitioning from one `Response` resState to another.
type ResponseStateTransition m (res :: ResponseState -> Type) (from :: ResponseState) (to :: ResponseState) =
  forall req reqState comp.
  Middleware
  m
  (Conn req reqState res from comp)
  (Conn req reqState res to comp)
  Unit

-- | The operations that a response writer, provided by the server backend,
-- | must support.
class Response (res :: ResponseState -> Type) m b | res -> b where
  writeStatus
    :: Status
    -> ResponseStateTransition m res StatusLineOpen HeadersOpen
  writeHeader
    :: Header
    -> ResponseStateTransition m res HeadersOpen HeadersOpen
  closeHeaders
    :: ResponseStateTransition m res HeadersOpen BodyOpen
  send
    :: b
    -> ResponseStateTransition m res BodyOpen BodyOpen
  end
    :: ResponseStateTransition m res BodyOpen ResponseEnded

headers
  :: forall f m req reqState (res :: ResponseState -> Type) b comp
  .  Foldable f
  => Monad m
  => Response res m b
  => f Header
  -> Middleware
     m
     (Conn req reqState res HeadersOpen comp)
     (Conn req reqState res BodyOpen comp)
     Unit
headers hs =
  traverse_ writeHeader hs
  :*> closeHeaders

contentType
  :: forall m req reqState (res :: ResponseState -> Type) b comp
  .  Monad m
  => Response res m b
   => MediaType
   -> Middleware
       m
       (Conn req reqState res HeadersOpen comp)
       (Conn req reqState res HeadersOpen comp)
       Unit
contentType mediaType =
  writeHeader (Tuple "Content-Type" (unwrap mediaType))

redirect
  :: forall m req reqState (res :: ResponseState -> Type) b comp
  .  Monad m
  => Response res m b
  => String
  -> Middleware
     m
     (Conn req reqState res StatusLineOpen comp)
     (Conn req reqState res HeadersOpen comp)
     Unit
redirect uri =
  writeStatus statusFound
  :*> writeHeader (Tuple "Location" uri)

class ResponseWritable b m r where
  toResponse :: forall i. r -> Middleware m i i b

respond
  :: forall m r b req reqState (res :: ResponseState -> Type) comp
  .  Monad m
  => ResponseWritable b m r
  => Response res m b
  => r
  -> Middleware
     m
     (Conn req reqState res BodyOpen comp)
     (Conn req reqState res ResponseEnded comp)
     Unit
respond r = (toResponse r :>>= send) :*> end
