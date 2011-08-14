{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

module Snap.Snaplet.Internal.Types where

import           Prelude hiding ((.))
import           Control.Applicative
import           Control.Category ((.))
import           Control.Monad.CatchIO hiding (Handler)
import           Control.Monad.Reader
import           Control.Monad.State.Class
import           Control.Monad.Trans.Writer hiding (pass)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import           Data.Configurator.Types
import           Data.IORef
import           Data.Monoid
import           Data.Lens.Lazy
import           Data.Lens.Template
import           Data.Text (Text)
import qualified Data.Text as T

import           Snap.Snaplet.Internal.Lens
import           Snap.Core


data SnapletConfig = SnapletConfig
    { _scAncestry        :: [Text]
    , _scFilePath        :: FilePath
    , _scId              :: Maybe Text
    , _scDescription     :: Text
    , _scUserConfig      :: Config
    , _scRouteContext    :: [ByteString]
    , _reloader          :: IO (Either String String) -- might change
    }


------------------------------------------------------------------------------
-- | Joins a reversed list of directories into a path.
buildPath :: [ByteString] -> ByteString
buildPath ps = B.intercalate "/" $ reverse ps


------------------------------------------------------------------------------
-- | Snaplet's type parameter 's' here is user-defined and can be any Haskell
-- type.  A value of type @Snaplet Foo@ countains a couple of things:
--
-- * a value of type @Foo@, called the \"user state\".
--
-- * some bookkeeping data the framework uses to plug things together, like the
--   snaplet's configuration, the snaplet's root directory on the filesystem,
--   the snaplet's root URL, and so on.
data Snaplet s = Snaplet
    { _snapletConfig :: SnapletConfig
    , _value         :: s
    }


instance Functor Snaplet where
    fmap f (Snaplet c v) = (Snaplet c (f v))


makeLenses [''SnapletConfig, ''Snaplet]


------------------------------------------------------------------------------
-- | A lens to get the user defined state out of a Snaplet.
snapletValue :: Lens (Snaplet a) a
snapletValue = value


------------------------------------------------------------------------------
-- | Transforms a lens of the type you get from makeLenses to an similar lens
-- that is more suitable for internal use.
subSnaplet :: (Lens a (Snaplet b)) -> (Lens (Snaplet a) (Snaplet b))
subSnaplet = (. value)


------------------------------------------------------------------------------
-- | The m type parameter used in the MonadSnaplet type signatures will
-- almost always be either Initializer or Handler.
--
-- Minimal complete definition:
--
-- * 'withTop'', 'with'', and all of the getXYZ functions.
--
class MonadSnaplet m where
    -- | Runs a child snaplet action in the current snaplet's context.  If you
    -- think about snaplet lenses using a filesystem path metaphor, the lens
    -- supplied to this snaplet must be a relative path.  In other words, the
    -- lens's base state must be the same as the current snaplet.
    with :: (Lens v (Snaplet v'))
         -- ^ A relative lens identifying a snaplet
         -> m b v' a
         -- ^ Action from the lense's snaplet
         -> m b v a
    with = with' . subSnaplet

    -- | Like 'with' but doesn't impose the requirement that the action
    -- being run be a descendant of the current snaplet.  Using our filesystem
    -- metaphor again, the lens for this function must be an absolute
    -- path--it's base must be the same as the current base.
    withTop :: (Lens b (Snaplet v'))
            -- ^ An "absolute" lens identifying a snaplet
            -> m b v' a
            -- ^ Action from the lense's snaplet
            -> m b v a
    withTop l = withTop' (subSnaplet l)

    -- | A variant of with accepting another kind of lens formulation
    -- that has an identity.  The lenses generated by 'mkLabels' will not
    -- work with this function, however the lens returned by 'getLens' will.
    --
    -- @with = with' . subSnaplet@
    with' :: (Lens (Snaplet v) (Snaplet v')) -> m b v' a -> m b v a

    -- Not providing a definition for this function in terms of withTop'
    -- allows us to avoid extra Monad type class constraints, making the type
    -- signature easier to read.
    -- with' l m = flip withTop m . (l .) =<< getLens

    -- | The absolute version of 'with''
    withTop' :: (Lens (Snaplet b) (Snaplet v')) -> m b v' a -> m b v a

    -- | Gets the lens for the current snaplet.
    getLens :: m b v (Lens (Snaplet b) (Snaplet v))

    -- | Gets a list of the names of snaplets that are direct ancestors of the
    -- current snaplet.
    getSnapletAncestry :: m b v [Text]

    -- | Gets the snaplet's path on the filesystem.
    getSnapletFilePath :: m b v FilePath

    -- | Gets the current snaple's name.
    getSnapletName :: m b v (Maybe Text)

    -- | Gets the current snaple's name.
    getSnapletDescription :: m b v Text

    -- | Gets the config data structure for the current snaplet.
    getSnapletConfig :: m b v Config

    -- | Gets the base URL for the current snaplet.  Directories get added to
    -- the current snaplet path by calls to `nestSnaplet`.
    getSnapletRootURL :: m b v ByteString


wrap' :: (MonadSnaplet m, Monad (m b b), Monad (m b v'))
      => (m b v  a -> m b v' a)
      -> (m b v  a -> m b v  a)
      -> (m b v' a -> m b v' a)
wrap' proj _filter m = do
    currentLens <- getLens
    proj (_filter (withTop' currentLens m))

------------------------------------------------------------------------------
-- | Applies a "filter" style function on snaplet monads with a descendent
-- snaplet.
wrap :: (MonadSnaplet m, Monad (m b b), Monad (m b v'))
     => (Lens (Snaplet v') (Snaplet v))
     -> (m b v  a -> m b v  a)
     -> (m b v' a -> m b v' a)
wrap l = wrap' (with' l)


------------------------------------------------------------------------------
-- | Applies a "filter" style function on snaplet monads with a sibling
-- snaplet.
wrapTop :: (MonadSnaplet m, Monad (m b b), Monad (m b v'))
        => (Lens (Snaplet b) (Snaplet v))
        -> (m b v  a -> m b v  a)
        -> (m b v' a -> m b v' a)
wrapTop l = wrap' (withTop' l)


------------------------------------------------------------------------------
newtype Handler b v a =
    Handler (LensT (Snaplet b) (Snaplet v) (Snaplet b) Snap a)
  deriving ( Monad
           , Functor
           , Applicative
           , MonadIO
           , MonadPlus
           , MonadCatchIO
           , Alternative
           , MonadSnap)


-- It's looking like we won't need these.
-- TODO If they're not being used, take them out before release.
type family Base (m :: * -> *) :: *
type family Env (m :: * -> *) :: *


hConfig :: Handler b v SnapletConfig
hConfig = Handler $ liftM _snapletConfig get


instance MonadSnaplet Handler where
    getLens = Handler ask
    with' !l (Handler !m) = Handler $ withLens l m
    withTop' !l (Handler m) = Handler $ downcast $ withLens l m
    getSnapletAncestry = return . _scAncestry =<< hConfig
    getSnapletFilePath = return . _scFilePath =<< hConfig
    getSnapletName = return . _scId =<< hConfig
    getSnapletDescription = return . _scDescription =<< hConfig
    getSnapletConfig = return . _scUserConfig =<< hConfig
    getSnapletRootURL = do
        ctx <- liftM _scRouteContext hConfig
        return $ buildPath ctx


------------------------------------------------------------------------------
-- | Handler that reloads the site.
reloadSite :: Handler b v ()
reloadSite = failIfNotLocal $ do
    cfg <- hConfig
    !res <- liftIO $ _reloader cfg
    either bad good res
  where
    bad msg = do
        writeText $ "Error reloading site!\n\n"
        writeText $ T.pack msg
    good msg = do
        writeText $ T.pack msg
        writeText $ "Site successfully reloaded.\n"
    failIfNotLocal m = do
        rip <- liftM rqRemoteAddr getRequest
        if not $ elem rip [ "127.0.0.1"
                          , "localhost"
                          , "::1" ]
          then pass
          else m


------------------------------------------------------------------------------
-- | Information about a partially constructed initializer.  Used to
-- automatically aggregate handlers and cleanup actions.
data InitializerState b = InitializerState
    { _isTopLevel      :: Bool
    , _cleanup         :: IO ()
    , _handlers        :: [(ByteString, Handler b b ())]
    -- ^ Handler routes built up and passed to route.
    , _hFilter         :: Handler b b () -> Handler b b ()
    -- ^ Generic filtering of handlers
    , _curConfig       :: SnapletConfig
    -- ^ This snaplet config is the incrementally built config for whatever
    -- snaplet is currently being constructed.
    , _initMessages    :: IORef Text
    }


------------------------------------------------------------------------------
-- | Wrapper around IO actions that modify state elements created during
-- initialization.
newtype Hook a = Hook (Snaplet a -> IO (Snaplet a))


instance Monoid (Hook a) where
    mempty = Hook return
    (Hook a) `mappend` (Hook b) = Hook (a >=> b)


------------------------------------------------------------------------------
-- | Monad used for initializing snaplets.
newtype Initializer b v a = 
    Initializer (LensT (Snaplet b)
                       (Snaplet v)
                       (InitializerState b)
                       (WriterT (Hook b) IO)
                       a)
  deriving (Applicative, Functor, Monad, MonadIO)

makeLenses [''InitializerState]


iConfig :: Initializer b v SnapletConfig
iConfig = Initializer $ liftM _curConfig getBase


instance MonadSnaplet Initializer where
    getLens = Initializer ask
    with' !l (Initializer !m) = Initializer $ withLens l m
    withTop' !l (Initializer m) = Initializer $ downcast $ withLens l m

    getSnapletAncestry = return . _scAncestry =<< iConfig
    getSnapletFilePath = return . _scFilePath =<< iConfig
    getSnapletName = return . _scId =<< iConfig
    getSnapletDescription = return . _scDescription =<< iConfig
    getSnapletConfig = return . _scUserConfig =<< iConfig
    getSnapletRootURL = do
        ctx <- liftM _scRouteContext iConfig
        return $ buildPath ctx


------------------------------------------------------------------------------
-- | Opaque newtype which gives us compile-time guarantees that the user is
-- using makeSnaplet and nestSnaplet correctly.
newtype SnapletInit b v = SnapletInit (Initializer b v (Snaplet v))


------------------------------------------------------------------------------
-- | Information needed to reload a site.  Instead of having snaplets define
-- their own reload actions, we store the original site initializer and use it
-- instead.
data ReloadInfo b = ReloadInfo
    { riRef     :: IORef (Snaplet b)
    , riAction  :: Initializer b b b
    }


------------------------------------------------------------------------------
instance MonadState v (Handler b v) where
    get = liftM _value lhGet
    put v = do
        s <- lhGet
        lhPut $ s { _value = v }

lhGet :: Handler b v (Snaplet v)
lhGet = Handler get
{-# INLINE lhGet #-}

lhPut :: Snaplet v -> Handler b v ()
lhPut = Handler . put
{-# INLINE lhPut #-}

