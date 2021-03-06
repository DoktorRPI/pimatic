###
Plugin Manager
=======
###

fs = require 'fs'
path = require 'path'
Q = require 'q'
util = require 'util'
assert = require 'cassert'
byline = require 'byline'
_ = require 'lodash'
spawn = require("child_process").spawn
https = require "https"
semver = require "semver"

env = null

class PluginManager

  constructor: (_env, @framework) ->
    env = _env
    @modulesParentDir = path.resolve @framework.maindir, '../../'

  # Loads the given plugin by name
  loadPlugin: (name) ->
    return Q.fcall =>     
      # If the plugin folder already exist
      promise = 
        if @isInstalled name 
          # We could instal the depencies...
          # @installDependencies name
          # but it takes so long
          Q()
        else 
          # otherwise install the plugin from the npm repository
          @installPlugin name

      # After installing
      return promise.then( =>
        # require the plugin and return it
        return plugin = (require name) env, module
      )
  # Checks if the plugin folder exists under node_modules
  isInstalled: (name) ->
    assert name?
    assert name.match(/^pimatic-.*$/)?
    return fs.existsSync(@pathToPlugin name)

  # Install a plugin from the npm repository
  installPlugin: (name) ->
    assert name?
    assert name.match(/^pimatic-.*$/)?
    return @spawnNpm(['install', name])

  update: (modules) -> 
    return @spawnNpm(['update'].concat modules)

  pathToPlugin: (name) ->
    assert name?
    assert name.match(/^pimatic-.*$/)? or name is "pimatic"
    return path.resolve @framework.maindir, "..", name

  searchForPlugins: ->
    plugins = [ 
      'pimatic-cron',
      'pimatic-datalogger',
      'pimatic-filebrowser',
      'pimatic-gpio',
      'pimatic-log-reader',
      'pimatic-mobile-frontend',
      'pimatic-pilight',
      'pimatic-ping',
      'pimatic-redirect',
      'pimatic-rest-api',
      'pimatic-shell-execute',
      'pimatic-sispmctl'
    ]
    waiting = []
    found = {}
    for p in plugins
      do (p) =>
        waiting.push @getNpmInfo(p).then( (info) =>
          found[p] = info
        )
    return Q.allSettled(waiting).then( (results) =>
      env.logger.error(r.reason) for r in results when r.state is "rejected"
      return found
    ).catch( (e) => env.logger.error e )

  isPimaticOutdated: ->
    installed = @getInstalledPackageInfo("pimatic")
    return @getNpmInfo("pimatic").then( (latest) =>
      if semver.gt(latest.version, installed.version)
        return {
          current: installed.version
          latest: latest.version
        }
      else return false
    )

  getOutdatedPlugins: ->
    return @getInstalledPlugins().then( (plugins) =>
      waiting = []
      infos = []
      for p in plugins
        do (p) =>
          installed = @getInstalledPackageInfo(p)
          waiting.push @getNpmInfo(p).then( (latest) =>
            infos.push {
              plugin: p
              current: installed.version
              latest: latest.version
            }
          )
      return Q.allSettled(waiting).then( (results) =>
        env.logger.error(r.reason) for r in results when r.state is "rejected"

        ret = []
        for info in infos
          unless info.current?
            env.logger.warn "Could not get installed package version of #{info.plugin}"
            continue
          unless info.latest?
            env.logger.warn "Could not get latest version of #{info.plugin}"
            continue
          ret.push info
        return ret
      )
    )

  spawnNpm: (args) ->
    deferred = Q.defer()
    if @npmRunning
      deferred.reject "npm is currently in use"
      return deferred.promise
    @npmRunning = yes
    output = ''
    npm = spawn('npm', args, cwd: @modulesParentDir)
    stdout = byline(npm.stdout)
    stdout.on "data", (line) => 
      line = line.toString()
      output += "#{line}\n"
      if line.indexOf('npm http 304') is 0 then return
      env.logger.info line
    stderr = byline(npm.stderr)
    stderr.on "data", (line) => 
      line = line.toString()
      output += "#{line}\n"
      env.logger.info line.toString()

    npm.on "close", (code) =>
      @npmRunning = no
      command = "npm " + _.reduce(args, (akk, a) -> "#{akk} #{a}")
      if code isnt 0
        deferred.reject new Error("Error running \"#{command}\"")
      else deferred.resolve(output)

    return deferred.promise
    

  getInstalledPlugins: ->
    return Q.nfcall(fs.readdir, "#{@framework.maindir}/..").then( (files) =>
      return plugins = (f for f in files when f.match(/^pimatic-.*/)?)
    ) 

  getInstalledPackageInfo: (name) ->
    assert name?
    assert name.match(/^pimatic-.*$/)? or name is "pimatic"
    return JSON.parse fs.readFileSync(
      "#{@pathToPlugin name}/package.json", 'utf-8'
    )

  getNpmInfo: (name) ->
    deferred = Q.defer()
    https.get("https://registry.npmjs.org/#{name}/latest", (res) =>
      str = ""
      res.on "data", (chunk) -> str += chunk
      res.on "end", ->
        try
          info = JSON.parse(str)
          if info.error? then throw new Error("getting info about #{name} failed: #{info.reason}")
          deferred.resolve info
        catch e
          deferred.reject e.message
    ).on "error", deferred.reject
    return deferred.promise


class Plugin extends require('events').EventEmitter
  name: null
  init: ->
    throw new Error("your plugin must implement init")

  #createDevice: (config) ->

module.exports.PluginManager = PluginManager
module.exports.Plugin = Plugin