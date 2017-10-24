module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  M = env.matcher
  _ = env.require('lodash')

  mpd = require "mpd"
  Promise.promisifyAll(mpd.prototype)


  # ###MpdPlugin class
  class MpdPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) ->

      deviceConfigDef = require("./device-config-schema")

      @framework.deviceManager.registerDeviceClass("MpdPlayer", {
        configDef: deviceConfigDef.MpdPlayer, 
        createCallback: (config) => new MpdPlayer(config)
      })

      #client.on("system", (name) -> console.log "update", name )

  class MpdPlayer extends env.devices.AVPlayer

    constructor: (@config) ->
      @name = @config.name
      @id = @config.id
      @_connect()
      super()

    destroy: () ->
      @_cancelReconnect()
      if @_client?
        # we need to remove event listeners as a spurious close or error event
        # may create another connection
        @_client.removeAllListeners()
        # add an empty error handler just in case the the mpd client raises an error event
        # which might occur as it is not possible to orderly close the connection
        @_client.on("error", ->)
        # make sure socket connection gets closed as the client object won't be
        # removed otherwise
        @_client.socket.destroy()
      super()

    _connect: () ->
      env.logger.debug("Connection to mpd #{@config.host}:#{@config.port}")
      if @_client?
        @_client.removeAllListeners()
        # add an empty error handler just in case the the previous mpd client raises an error event
        # which might occur as it is not possible to orderly close the connection
        @_client.on("error", ->)
      @_client = mpd.connect(
        port: @config.port
        host: @config.host      
      )

      errorHandler = (err) =>
        env.logger.debug("Error on connection to mpd: #{err.message}")
        @_reconnect()

      @_connectionPromise = new Promise( (resolve, reject) =>
        onReady = =>
          @_lastError = null
          @_client.removeListener('error', onError)
          @_client.on("error", => errorHandler)
          resolve()
        onError = (err) =>
          @_client.removeListener('ready', onReady)
          reject(err)
        @_client.once("ready", onReady)
        @_client.once("error", onError)
        return
      )

      @_connectionPromise.then( => @_updateInfo() ).catch( (err) =>
        if @_lastError?.message is err.message
          return
        @_lastError = err
        env.logger.error "Error on connecting to mpd: #{err.message}"
        env.logger.debug err.stack
      )

      @_client.on("system-player", =>
        return @_updateInfo().catch( (err) =>
          env.logger.error "Error sending mpd command: #{err.message}"
          env.logger.debug err.stack
        )
      )

      @_client.on("system-mixer", =>
        return @_updateInfo().catch( (err) =>
          env.logger.error "Error sending mpd command: #{err.message}"
          env.logger.debug err.stack
        )
      )

      @_client.on("end", =>
        env.logger.debug("Connection to mpd lost")
        @_reconnect()
      )

    _cancelReconnect: () ->
      clearTimeout(@_timeoutId) if @_timeoutId?
      @_timeoutId = null

    _reconnect: () ->
      @_cancelReconnect()
      @_timeoutId = setTimeout((=> @_timeoutId = null; @_connect()), 10000)

    play: () ->
      switch @_state
        when 'stop' then @_sendCommandAction('play')
        when 'pause' then @_sendCommandAction('pause', '0')
        else Promise.resolve()
    pause: () -> @_sendCommandAction('pause', '1')
    stop: () -> @_sendCommandAction('stop')
    previous: () -> @_sendCommandAction('previous')
    next: () -> @_sendCommandAction('next')
    setVolume: (volume) -> @_sendCommandAction('setvol', volume)

    _updateInfo: -> Promise.all([@_getStatus(), @_getCurrentSong()])

    _getStatus: () ->
      @_client.sendCommandAsync(mpd.cmd("status", [])).then( (msg) =>
        info = mpd.parseKeyValueMessage(msg)
        @_setState(info.state)
        @_setVolume(info.volume)
        #if info.songid isnt @_currentTrackId
      )

    _getCurrentSong: () ->
      @_client.sendCommandAsync(mpd.cmd("currentsong", [])).then( (msg) =>
        info = mpd.parseKeyValueMessage(msg)
        @_setCurrentTitle(if info.Title? then info.Title else "")
        @_setCurrentArtist(if info.Name? then info.Name else "")
      ).catch( (err) =>
        env.logger.error "Error sending mpd command: #{err.message}"
        env.logger.debug err.stack
      )

    _sendCommandAction: (action, args...) ->
      return @_connectionPromise.then( =>
        return @_client.sendCommandAsync(mpd.cmd(action, args)).then( (msg) =>
          return
        )
      )
      
  # ###Finally
  # Create a instance of my plugin
  mpdPlugin = new MpdPlugin
  # and return it to the framework.
  return mpdPlugin