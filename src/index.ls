VERSION = '0.1.0'

{id, map, compact, any, group-by, chars, is-it-NaN, keys, Obj} = require 'prelude-ls'
deep-is = require 'deep-is'
{closest-string, name-to-raw, camelize, dasherize} = require './util'
{generate-help, generate-help-for-option} = require './help'
{parsed-type-check, parse-type} = require 'type-check'
{parsed-type-parse: parse-levn} = require 'levn'

camelize-keys = (obj) -> {[(camelize key), value] for key, value of obj}

parse-string = (string) ->
  assign-opt = '--?[a-zA-Z][-a-z-A-Z0-9]*='
  regex = //
      (?:#assign-opt)?(?:'(?:[^']|\\')+'|"(?:[^"]|\\")+")
    | [^'"\s]+
  //g
  replace-regex = //^(#assign-opt)?['"]([\s\S]*)['"]$//
  result = map (.replace replace-regex, '$1$2'), (string.match regex or [])
  result

main = (lib-options) ->
  opts = {}
  defaults = {}
  required = []
  if typeof! lib-options.stdout is 'Undefined'
    lib-options.stdout = process.stdout

  traverse = (options) !->
    throw new Error 'No options defined.' unless typeof! options is 'Array'

    for option in options when not option.heading?
      name = option.option
      throw new Error "Option '#name' already defined." if opts[name]?

      option.boolean ?= true if option.type is 'Boolean'

      unless option.parsed-type?
        throw new Error "No type defined for option '#name'." unless option.type
        try
            option.parsed-type = parse-type option.type
        catch
          throw new Error "Option '#name': Error parsing type '#{option.type}': #{e.message}"

      if option.default
        try
          defaults[name] = parse-levn option.parsed-type, option.default
        catch
          throw new Error "Option '#name': Error parsing default value '#{option.default}' for type '#{option.type}': #{e.message}"

      if option.enum and not option.parsed-possiblities
        parsed-possibilities = []
        parsed-type = option.parsed-type
        for possibility in option.enum
          try
              parsed-possibilities.push parse-levn parsed-type, possibility
          catch
            throw new Error "Option '#name': Error parsing enum value '#possibility' for type '#{option.type}': #{e.message}"
        option.parsed-possibilities = parsed-possibilities

      required.push name if option.required

      opts[name] = option

      if option.alias or option.aliases
        throw new Error "-NUM option can't have aliases." if name is 'NUM'
        option.aliases ?= [].concat option.alias if option.alias
        for alias in option.aliases
          throw new Error "Option '#alias' already defined." if opts[alias]?
          opts[alias] = option

  traverse lib-options.options

  get-option = (name) ->
    opt = opts[name]
    unless opt?
      possibly-meant = closest-string (keys opts), name
      throw new Error "Invalid option '#{ name-to-raw name}'#{ if possibly-meant then " - perhaps you meant '#{ name-to-raw possibly-meant }'?" else '.'}"
    opt

  parse = (input, {slice} = {}) ->
    obj = {}
    positional = []
    rest-positional = false
    prop = null

    set-value = (name, value) !->
      opt = get-option name
      if opt.boolean
        val = value
      else
        try
          val = parse-levn opt.parsed-type, value
        catch
          throw new Error "Invalid value for option '#name' - expected type #{opt.type}, received value: #value."
        if opt.enum and not any (-> deep-is it, val), opt.parsed-possibilities
          throw new Error "Option #name: '#val' not in [#{ opt.enum.join ', ' }]."

      obj[name] = val
      rest-positional := true if opt.rest-positional

    set-defaults = !->
      for name, value of defaults
        unless obj[name]?
          obj[name] = value

    check-required = !->
      for name in required
        throw new Error "Option #{ name-to-raw name} is required." unless obj[name]

    mutually-exclusive-error = (first, second) ->
        throw new Error "The options #{ name-to-raw first } and #{ name-to-raw second } are mutually exclusive - you cannot use them at the same time."

    check-mutually-exclusive = !->
      rules = lib-options.mutually-exclusive
      return unless rules

      for rule in rules
        present = null
        for element in rule
          if typeof! element is 'Array'
            for opt in element
              if opt of obj
                if present?
                  mutually-exclusive-error present, opt
                else
                  present = opt
                  break
          else
            if element of obj
              if present?
                mutually-exclusive-error present, element
              else
                present = element

    switch typeof! input
    | 'String'
      args = parse-string input.slice slice ? 0
    | 'Array'
      args = input.slice (slice ? 2) # slice away "node" and "filename" by default
    | 'Object'
      obj = {}
      for key, value of input when key isnt '_'
        option = get-option (dasherize key)
        if parsed-type-check option.parsed-type, value
          obj[option.option] = value
        else
          throw new Error "Option '#{option.option}': Invalid type for '#value' - expected type '#{option.type}'."
      check-mutually-exclusive!
      set-defaults!
      check-required!
      obj._ = input._ or []
      return camelize-keys obj
    | otherwise
      throw new Error "Invalid argument to 'parse': #input."

    for arg in args
      if arg is '--'
        rest-positional := true
      else if rest-positional
        positional.push arg
      else
        if arg.match /^(--?)([a-zA-Z][-a-zA-Z0-9]*)(=)?(.*)?$/
          result = that
          throw new Error "Value for '#prop' of type '#{ get-option prop .type}' required." if prop

          short = result.1.length is 1
          arg-name = result.2
          using-assign = result.3?
          val = result.4
          throw new Error "No value for '#arg-name' specified." if using-assign and not val?

          if short
            flags = chars arg-name
            len = flags.length
            for flag, i in flags
              opt = get-option flag
              name = opt.option
              if rest-positional
                positional.push flag
              else if opt.boolean
                set-value name, true
              else if i is len - 1
                if using-assign
                  set-value name, val
                else
                  prop := name
              else
                throw new Error "Can't set argument '#flag' when not last flag in a group of short flags."
          else
            negated = false
            if arg-name.match /^no-(.+)$/
              negated = true
              noed-name = that.1
              opt = get-option noed-name
            else
              opt = get-option arg-name

            name = opt.option
            if opt.boolean
              val-prime = if using-assign then parse-levn [type: 'Boolean'], val else true
              if negated
                set-value name, not val-prime
              else
                set-value name, val-prime
            else
              throw new Error "Only use 'no-' prefix for Boolean options, not with '#noed-name'." if negated
              if using-assign
                set-value name, val
              else
                prop := name
        else if arg.match /^-([0-9]+(?:\.[0-9]+)?)$/
          opt = opts.NUM
          throw new Error 'No -NUM option defined.' unless opt
          set-value opt.option, that.1
        else
          if prop
            set-value prop, arg
            prop := null
          else
            positional.push arg

    check-mutually-exclusive!
    set-defaults!
    check-required!
    obj._ = positional
    camelize-keys obj

  parse: parse
  generate-help: generate-help lib-options
  generate-help-for-option: generate-help-for-option get-option, lib-options

main <<< {VERSION}
module.exports = main