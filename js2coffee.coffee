# {{{ Imports
TransformerBase = require('./lib/transformer_base')
BuilderBase = require('./lib/builder_base')

{
  buildError
  clone
  commaDelimit
  delimit
  inspect
  newline
  prependAll
  replace
  space
} = require('./lib/helpers')
# }}}

module.exports = js2coffee = (source, options) ->
  js2coffee.build(source, options).code

# ---------------------------------------------------------------------------
# {{{ Build

###*
# # Js2coffee API
###

###*
# build() : js2coffee.build(source, [options])
# Compiles JavaScript into CoffeeScript.
#
#     output = js2coffee.build('a = 2', {});
#
#     output.code
#     output.ast
#     output.map
#
# All options are optional. Available options are:
#
# ~ filename (String): the filename, used in source maps and errors.
# ~ comments (Boolean): set to `false` to disable comments.
#
# How it works:
#
# 1. It uses Esprima to convert the input into a JavaScript AST.
# 2. It uses AST transformations (see [js2coffee.transform]) to mutate the AST
#    into a CoffeeScript AST.
# 3. It generates cofe (see [js2coffee.generate]) to compile the CoffeeScript
#    AST into CoffeeScript code.
###

js2coffee.build = (source, options = {}) ->
  options.filename ?= 'input.js'
  options.source = source

  ast = js2coffee.parseJS(source, options)
  ast = js2coffee.transform(ast, options)
  {code, map} = js2coffee.generate(ast, options)
  {code, ast, map}

###*
# parseJS() : js2coffee.parseJS(source, [options])
# Parses JavaScript code into an AST via Esprima.
#
#     try
#       ast = js2coffee.parseJS('var a = 2;')
#     catch err
#       ...
###

js2coffee.parseJS = (source, options = {}) ->
  try
    Esprima = require('esprima')
    Esprima.parse(source, loc: true, range: true, comment: true)
  catch err
    throw buildError(err, source, options.filename)

###*
# transform() : js2coffee.transform(ast, [options])
# Mutates a given JavaScript syntax tree `ast` into a CoffeeScript AST.
#
#     ast = js2coffee.parseJS('var a = 2;')
#     ast = js2coffee.transform(ast)
#
# This performs a few traversals across the tree using traversal classes
# (TransformerBase subclasses).
###

js2coffee.transform = (ast, options = {}) ->
  # Note that these transformations will need to be done in a few steps.
  # The earlier steps (function, comment, etc) will make drastic modifications
  # to the tree that the other transformations will need to pick up.
  run = (classes) ->
    TransformerBase.run(ast, options, classes)

  # Injects comments into the AST as BlockComment and LineComment nodes.
  unless options.comments is false
    run [ CommentTransforms ]

  # Moves named functions to the top of the scope.
  run [ FunctionTransforms ]

  run [ PrecedenceTransforms ]

  # Everything else -- these can be done in one step without any side effects.
  run [
    LoopTransforms
    SwitchTransforms
    MemberTransforms
    ObjectTransforms
    OtherTransforms ]
  run [ BlockTransforms ]

  ast

###*
# generate() : js2coffee.generate(ast, [options])
# Generates CoffeeScript code from a given CoffeeScript AST. Returns an object
# with `code` (CoffeeScript source code) and `map` (source mapping object).
#
#     ast = js2coffee.parse('var a = 2;')
#     ast = js2coffee.transform(ast)
#     {code, map} = generate(ast)
###

js2coffee.generate = (ast, options = {}) ->
  new Builder(ast, options).get()

# }}} -----------------------------------------------------------------------
# {{{ CommentTransforms

###
# Injects comments as nodes in the AST. This takes the comments in the
# `Program` node, finds list of expressions in bodies (eg, a BlockStatement's
# `body`), and injects the comment nodes wherever relevant.
#
# Comments will be injected as `BlockComment` and `LineComment` nodes.
###

class CommentTransforms extends TransformerBase
  # Disable the stack-tracking for now
  ProgramExit: null
  FunctionExpression: null
  FunctionExpressionExit: null

  Program: (node) ->
    @comments = node.comments
    @updateCommentTypes()
    @BlockStatement node

  BlockStatement: (node) ->
    @injectComments(node, 'body')

  SwitchStatement: (node) ->
    @injectComments(node, 'cases')

  SwitchCase: (node) ->
    @injectComments(node, 'consequent')

  BlockComment: (node) ->
    @convertCommentPrefixes(node)

  ###
  # Updates comment `type` as needed. It changes *Block* to *BlockComment*, and
  # *Line* to *LineComment*. This makes it play nice with the rest of the AST,
  # because "Block" and "Line" are ambiguous.
  ###

  updateCommentTypes: ->
    for c in @comments
      switch c.type
        when 'Block' then c.type = 'BlockComment'
        when 'Line'  then c.type = 'LineComment'

  ###
  # Injects comment nodes into a node list.
  ###

  injectComments: (node, key) ->
    node[key] = @addCommentsToList(node.range, node[key])
    node

  ###
  # Delegate of `injectComments()`.
  #
  # Checks out the `@comments` list for any relevants comments, and injects
  # them into the correct places in the given `body` Array. Returns the
  # transformed `body` array.
  ###

  addCommentsToList: (range, body) ->
    return body unless range?

    list = []
    left = range[0]
    right = range[1]

    # look for comments in left..node.range[0]
    for item, i in body
      if item.range
        newComments = @comments.filter (c) ->
          c.range[0] >= left and c.range[1] <= item.range[0]
        list = list.concat(newComments)

      list.push item

      if item.range
        left = item.range[1]
    list

  ###
  # Changes JS block comments into CoffeeScript block comments.
  # This involves changing prefixes like `*` into `#`.
  ###

  convertCommentPrefixes: (node) ->
    lines = node.value.split("\n")
    lines = lines.map (line, i) ->
      isTrailingSpace = i is lines.length-1 and line.match(/^\s*$/)
      isSingleLine = i is 0 and lines.length is 1

      if isTrailingSpace
        ''
      else if isSingleLine
        line
      else
        line = line.replace(/^ \*/, '#')
        line + "\n"
    node.value = lines.join("")
    node

# }}} -----------------------------------------------------------------------
# {{{ SwitchTransforms

###
# Updates `SwitchCase`s to a more coffee-compliant AST. This means having
# to remove `return`/`break` statements, and taking into account the
# correct way of consolidating empty ccases.
#
#     switch (x) { case a: b(); break; }
#
#     switch x
#       when a then b()
###

class SwitchTransforms extends TransformerBase
  SwitchStatement: (node) ->
    @consolidateCases(node)

  SwitchCase: (node) ->
    @removeBreaksFromConsequents(node)

  ###
  # Consolidates empty cases into the next case. The case tests will then be
  # made into a new node type, CoffeeListExpression, to represent
  # comma-separated values. (`case x: case y: z()` => `case x, y: z()`)
  ###

  consolidateCases: (node) ->
    list = []
    toConsolidate = []
    for kase, i in node.cases
      # .type .test .consequent
      if kase.type is 'SwitchCase'
        toConsolidate.push(kase.test) if kase.test
        if kase.consequent.length > 0
          if kase.test
            kase.test =
              type: 'CoffeeListExpression'
              expressions: toConsolidate
          toConsolidate = []
          list.push kase
      else
        list.push kase

    node.cases = list
    node

  ###
  # Removes `break` statements from consequents in a switch case.
  # (eg, `case x: a(); break;` gets break; removed)
  ###

  removeBreaksFromConsequents: (node) ->
    if node.test
      idx = node.consequent.length-1
      last = node.consequent[idx]
      if last?.type is 'BreakStatement'
        delete node.consequent[idx]
        node.consequent.length -= 1
      else if last?.type isnt 'ReturnStatement'
        @syntaxError node, "No break or return statement found in a case"
      node

# }}} -----------------------------------------------------------------------
# {{{ MemberTransforms

###
# Performs transformations on `a.b` scope resolutions.
#
#     this.x            =>  @x
#     x.prototype.y     =>  x::y
#     this.prototype.y  =>  @::y
#     function(){}.y    =>  (->).y
###

class MemberTransforms extends TransformerBase
  MemberExpression: (node) ->
    @transformThisToAtSign(node)
    @replaceWithPrototype(node) or
    @parenthesizeObjectIfFunction(node)

  CoffeePrototypeExpression: (node) ->
    @transformThisToAtSign(node)

  ###
  # Converts `this.x` into `@x` for MemberExpressions.
  ###

  transformThisToAtSign: (node) ->
    if node.object.type is 'ThisExpression'
      node._prefixed = true
      node.object._prefix = true
    node

  ###
  # Replaces `a.prototype.b` with `a::b` in a member expression.
  ###

  replaceWithPrototype: (node) ->
    isPrototype = node.computed is false and
      node.object.type is 'MemberExpression' and
      node.object.property.type is 'Identifier' and
      node.object.property.name is 'prototype'
    if isPrototype
      @recurse replace node,
        type: 'CoffeePrototypeExpression'
        object: node.object.object
        property: node.property

  ###
  # Parenthesize function expressions if they're in the left-hand side of a
  # member expression (eg, `(-> x).toString()`).
  ###

  parenthesizeObjectIfFunction: (node) ->
    if node.object.type is 'FunctionExpression'
      node.object._parenthesized = true
    node

# }}} -----------------------------------------------------------------------
# {{{ ObjectTransforms

###
# Mangles the AST with various CoffeeScript tweaks.
###

class ObjectTransforms extends TransformerBase
  ArrayExpression: (node) ->
    @braceObjectsInElements(node)

  ObjectExpression: (node, parent) ->
    @braceObjectInExpression(node, parent)

  ###
  # Braces an object
  ###

  braceObjectInExpression: (node, parent) ->
    if parent.type is 'ExpressionStatement'
      isLastInScope = @scope.body?[@scope.body?.length-1] is parent

      if isLastInScope
        node._last = true
      else
        node._braced = true
    return

  ###
  # Ensures that an Array's elements objects are braced.
  ###

  braceObjectsInElements: (node) ->
    for item in node.elements
      if item.type is 'ObjectExpression'
        item._braced = true
    node

# }}} -----------------------------------------------------------------------
# {{{ OtherTransforms

###
# Mangles the AST with various CoffeeScript tweaks.
###

class OtherTransforms extends TransformerBase
  BlockStatementExit: (node) ->
    @removeEmptyStatementsFromBody(node)

  FunctionExpression: (node, parent) ->
    super(node)
    @removeUndefinedParameter(node)

  CallExpression: (node) ->
    @parenthesizeCallee(node)

  Identifier: (node) ->
    @escapeUndefined(node)

  BinaryExpression: (node) ->
    @updateBinaryExpression(node)

  UnaryExpression: (node) ->
    @updateVoidToUndefined(node)

  LabeledStatement: (node, parent) ->
    @warnAboutLabeledStatements(node, parent)

  WithStatement: (node) ->
    @syntaxError node, "'with' is not supported in CoffeeScript"

  VariableDeclarator: (node) ->
    @addShadowingIfNeeded(node)
    @addExplicitUndefinedInitializer(node)

  ReturnStatement: (node) ->
    @parenthesizeObjectsInArgument(node)

  Literal: (node) ->
    @unpackRegexpIfNeeded(node)

  ###
  # Accounts for regexps that start with an equal sign.
  ###

  unpackRegexpIfNeeded: (node) ->
    m = node.value.toString().match(/^\/(\=.*)\/$/)
    if m
      replace node,
        type: 'CallExpression'
        callee: { type: 'Identifier', name: 'RegExp' },
        arguments: [
          type: 'Literal'
          value: m[1]
          raw: JSON.stringify(m[1])
        ]

  ###
  # Ensures that a ReturnStatement with an object ('return {a:1}') has a braced
  # expression.
  ###

  parenthesizeObjectsInArgument: (node) ->
    if node.argument
      if node.argument.type is 'ObjectExpression'
        node.argument._braced = true
    node

  ###
  # Remove `{type: 'EmptyStatement'}` from the body.
  # Since estraverse doesn't support removing nodes from the AST, some filters
  # replace nodes with 'EmptyStatement' nodes. This cleans that up.
  ###

  removeEmptyStatementsFromBody: (node) ->
    node.body = node.body.filter (n) ->
      n.type isnt 'EmptyStatement'
    node

  ###
  # Adds a `var x` shadowing statement when encountering shadowed variables.
  # (See specs/shadowing/var_shadowing)
  ###

  addShadowingIfNeeded: (node) ->
    name = node.id.name
    if ~@ctx.vars.indexOf(name)
      statement = replace node,
        type: 'ExpressionStatement'
        expression:
          type: 'CoffeeEscapedExpression'
          raw: "var #{name}"
      @scope.body = [ statement ].concat(@scope.body)
    else
      @ctx.vars.push name

  ###
  # For VariableDeclarator with no initializers (`var a`), add `undefined` as
  # the initializer.
  ###

  addExplicitUndefinedInitializer: (node) ->
    unless node.init?
      node.init = { type: 'Identifier', name: 'undefined' }
      @skip()
    node

  ###
  # Produce warnings when using labels. It may be a JSON string being pasted,
  # so produce a more helpful warning for that case.
  ###

  warnAboutLabeledStatements: (node, parent) ->
    @syntaxError node, "Labeled statements are not supported in CoffeeScirpt"

  ###
  # Updates `void 0` UnaryExpressions to `undefined` Identifiers.
  ###

  updateVoidToUndefined: (node) ->
    if node.operator is 'void'
      replace node, type: 'Identifier', name: 'undefined'
    else
      node

  ###
  # Turn 'undefined' into '`undefined`'. This uses a new node type,
  # CoffeeEscapedExpression.
  ###

  escapeUndefined: (node) ->
    if node.name is 'undefined'
      replace node, type: 'CoffeeEscapedExpression', raw: 'undefined'
    else
      node

  ###
  # Updates binary expressions to their CoffeeScript equivalents.
  ###

  updateBinaryExpression: (node) ->
    dict =
      '===': '=='
      '!==': '!='
    op = node.operator
    if dict[op] then node.operator = dict[op]
    node

  ###
  # Removes `undefined` from function parameters.
  # (`function (a, undefined) {}` => `(a) ->`)
  ###

  removeUndefinedParameter: (node) ->
    if node.params
      for param, i in node.params
        isLast = i is node.params.length - 1
        isUndefined = param.type is 'Identifier' and param.name is 'undefined'

        if isUndefined
          if isLast
            node.params.pop()
          else
            @syntaxError node, "undefined is not allowed in function parameters"
    node

  ###
  # In an IIFE, ensure that the function expression is parenthesized (eg,
  # `(($)-> x) jQuery`).
  ###

  parenthesizeCallee: (node) ->
    if node.callee.type is 'FunctionExpression'
      node.callee._parenthesized = true
      node

# }}} -----------------------------------------------------------------------
# {{{ LoopTransforms

###
# Provides transformations for `while`, `for` and `do`.
###

class LoopTransforms extends TransformerBase
  ForStatement: (node) ->
    @injectUpdateIntoBody(node)
    @convertForToWhile(node)

  WhileStatement: (node) ->
    @convertToLoopStatement(node)

  ###
  # Converts a `for (x;y;z) {a}` to `x; while(y) {a; z}`.
  # Returns a `BlockStatement`.
  ###

  convertForToWhile: (node) ->
    node.type = 'WhileStatement'
    block =
      type: 'BlockStatement'
      body: [ node ]

    if node.init
      block.body.unshift
        type: 'ExpressionStatement'
        expression: node.init

    return block

  ###
  # Converts a `while (true)` to a CoffeeLoopStatement.
  ###

  convertToLoopStatement: (node) ->
    isLoop = not node.test? or
      (node.test?.type is 'Literal' and node.test?.value is true)

    if isLoop
      replace node,
        type: 'CoffeeLoopStatement'
        body: node.body
    else
      node

  ###*
  # Injects a ForStatement's update (eg, `i++`) into the body.
  ###

  injectUpdateIntoBody: (node) ->
    if node.update
      statement =
        type: 'ExpressionStatement'
        expression: node.update

      # Ensure that the body is a BlockStatement with a body
      if not node.body?
        node.body ?= { type: 'BlockStatement', body: [] }
      else if node.body.type isnt 'BlockStatement'
        old = node.body
        node.body = { type: 'BlockStatement', body: [ old ] }

      node.body.body = node.body.body.concat([statement])
      delete node.update

# }}} -----------------------------------------------------------------------
# {{{ BlockTransforms

###
# Flattens nested `BlockStatements`.
###

class BlockTransforms extends TransformerBase
  BlockStatement: (node, parent) ->
    if parent.type is 'BlockStatement'
      parent.body.splice parent.body.indexOf(node), 1, node.body...
      return

# }}} -----------------------------------------------------------------------
# {{{ FunctionTransforms

###
# FunctionTransforms:
# Reorders functions.
#
# * Moves function definitions (`function x(){}`) to the top of the scope and
#   turns them into variable declarations (`x = -> ...`).
#
# * Moves named function expressions (`setTimeout(function tick(){})`) to the
#   top of the scope.
###

class FunctionTransforms extends TransformerBase
  onScopeEnter: (scope, ctx) ->
    # Keep a list of things to be prepended before the body
    ctx.prebody = []

  onScopeExit: (scope, ctx, subscope, subctx) ->
    # prepend the functions back into the body
    if subctx.prebody.length
      scope.body = subctx.prebody.concat(scope.body)

  FunctionDeclaration: (node) ->
    @ctx.prebody.push @buildFunctionDeclaration(node)
    @pushStack(node.body)
    return

  FunctionDeclarationExit: (node) ->
    @popStack(node)
    { type: 'EmptyStatement' }

  FunctionExpression: (node) ->
    return unless node.id?
    @ctx.prebody.push @buildFunctionDeclaration(node)
    @pushStack(node.body)
    return

  FunctionExpressionExit: (node) ->
    return unless node.id?
    @popStack()
    { type: 'Identifier', name: node.id.name }

  ###
  # Returns a `a = -> ...` statement out of a FunctionDeclaration node.
  ###

  buildFunctionDeclaration: (node) ->
    replace node,
      type: 'VariableDeclaration'
      declarations: [
        type: 'VariableDeclarator'
        id: node.id
        init:
          type: 'FunctionExpression'
          params: node.params
          body: node.body
      ]

# }}} -----------------------------------------------------------------------
# {{{ PrecedenceTransforms

class PrecedenceTransforms extends TransformerBase

# }}} -----------------------------------------------------------------------
# {{{ Builder

###*
# Builder : new Builder(ast, [options])
# Generates output based on a JavaScript AST.
#
#     s = new Builder(ast, { filename: 'input.js', source: '...' })
#     s.get()
#     => { code: '...', map: { ... } }
#
# The params `options` and `source` are optional. The source code is used to
# generate meaningful errors.
###

class Builder extends BuilderBase

  constructor: (ast, options={}) ->
    super
    @_indent = 0

  ###*
  # indent():
  # Indentation utility with 3 different functions.
  #
  # - `@indent(-> ...)` - adds an indent level.
  # - `@indent([ ... ])` - adds indentation.
  # - `@indent()` - returns the current indent level as a string.
  #
  # When invoked with a function, the indentation level is increased by 1, and
  # the function is invoked. This is similar to escodegen's `withIndent`.
  #
  #     @indent =>
  #       [ '...' ]
  #
  # The past indent level is passed to the function as the first argument.
  #
  #     @indent (indent) =>
  #       [ indent, 'if', ... ]
  #
  # When invoked with an array, it will indent it.
  #
  #     @indent [ 'if...' ]
  #     #=> [ '  ', [ 'if...' ] ]
  #
  # When invoked without arguments, it returns the current indentation as a
  # string.
  #
  #     @indent()
  ###

  indent: (fn) ->
    if typeof fn is "function"
      previous = @indent()
      @_indent += 1
      result = fn(previous)
      @_indent -= 1
      result
    else if fn
      [ @indent(), fn ]
    else
      Array(@_indent + 1).join("  ")

  ###*
  # get():
  # Returns the output of source-map.
  ###

  get: ->
    @run().toStringWithSourceMap()

  ###*
  # decorator():
  # Takes the output of each of the node visitors and turns them into
  # a `SourceNode`.
  ###

  decorator: (node, output) ->
    {SourceNode} = require("source-map")
    new SourceNode(
      node?.loc?.start?.line,
      node?.loc?.start?.column,
      @options.filename,
      output)

  ###*
  # onUnknownNode():
  # Invoked when the node is not known. Throw an error.
  ###

  onUnknownNode: (node, ctx) ->
    @syntaxError(node, "#{node.type} is not supported")

  syntaxError: TransformerBase::syntaxError

  ###*
  # visitors:
  # The visitors of each node.
  ###

  Program: (node) ->
    @comments = node.comments
    @BlockStatement(node)

  ExpressionStatement: (node) ->
    newline @walk(node.expression)

  AssignmentExpression: (node) ->
    space [ @walk(node.left), node.operator, @walk(node.right) ]

  Identifier: (node) ->
    [ node.name ]

  UnaryExpression: (node) ->
    if (/^[a-z]+$/i).test(node.operator)
      [ node.operator, ' ', @walk(node.argument) ]
    else
      [ node.operator, @walk(node.argument) ]

  # Operator (+)
  BinaryExpression: (node) ->
    space [ @walk(node.left), node.operator, @walk(node.right) ]

  Literal: (node) ->
    [ node.raw ]

  MemberExpression: (node) ->
    right = if node.computed
      [ '[', @walk(node.property), ']' ]
    else if node._prefixed
      [ @walk(node.property) ]
    else
      [ '.', @walk(node.property) ]

    [ @walk(node.object), right ]

  LogicalExpression: (node) ->
    [ @walk(node.left), ' ', node.operator, ' ', @walk(node.right) ]

  ThisExpression: (node) ->
    if node._prefix
      [ "@" ]
    else
      [ "this" ]

  CallExpression: (node, ctx) ->
    callee = @walk(node.callee)
    list = @makeSequence(node.arguments)
    node._isStatement = ctx.parent.type is 'ExpressionStatement'

    hasArgs = list.length > 0

    if node._isStatement and hasArgs
      space [ callee, list ]
    else
      [ callee, '(', list, ')' ]

  IfStatement: (node) ->
    alt = node.alternate
    if alt?.type is 'IfStatement'
      els = @indent [ "else ", @walk(node.alternate, 'IfStatement') ]
    else if alt?.type is 'BlockStatement'
      els = @indent (i) => [ i, "else\n", @walk(node.alternate) ]
    else if alt?
      els = @indent (i) => [ i, "else\n", @indent(@walk(node.alternate)) ]
    else
      els = []

    @indent (i) =>
      test = @walk(node.test)
      consequent = @walk(node.consequent)
      if node.consequent.type isnt 'BlockStatement'
        consequent = @indent(consequent)

      [ 'if ', test, "\n", consequent, els ]

  BlockStatement: (node) ->
    @makeStatements(node, node.body)

  makeStatements: (node, body) ->
    prependAll(body.map(@walk), @indent())

  LineComment: (node) ->
    [ "#", node.value, "\n" ]

  BlockComment: (node) ->
    [ "###", node.value, "###\n" ]

  ReturnStatement: (node) ->
    if node.argument
      space [ "return", [ @walk(node.argument), "\n" ] ]
    else
      [ "return\n" ]

  ArrayExpression: (node) ->
    items = node.elements.length
    isSingleLine = items is 1

    if items is 0
      [ "[]" ]
    else if isSingleLine
      space [ "[", node.elements.map(@walk), "]" ]
    else
      @indent (indent) =>
        elements = node.elements.map (e) => newline @walk(e)
        contents = prependAll(elements, @indent())
        [ "[\n", contents, indent, "]" ]

  ObjectExpression: (node, ctx) ->
    props = node.properties.length
    isBraced = node._braced

    # Empty
    if props is 0
      [ "{}" ]

    # Single prop ({ a: 2 })
    else if props is 1
      props = node.properties.map(@walk)
      if isBraced
        space [ "{", props, "}" ]
      else
        [ props ]

    # Last expression in scope (`function() { ({a:2}); }`)
    else if node._last
      props = node.properties.map(@walk)
      return delimit(props, [ "\n", @indent() ])

    # Multiple props ({ a: 2, b: 3 })
    else
      props = @indent =>
        props = node.properties.map(@walk)
        prependAll(props, [ "\n", @indent() ])

      if isBraced
        [ "{", props, "\n", @indent(), "}" ]
      else
        [ props ]

  Property: (node) ->
    if node.kind isnt 'init'
      throw new Error("Property: not sure about kind " + node.kind)

    space [ [@walk(node.key), ":"], @walk(node.value) ]

  VariableDeclaration: (node) ->
    declarators = node.declarations.map(@walk)
    delimit(declarators, @indent())

  VariableDeclarator: (node) ->
    [ @walk(node.id), ' = ', newline(@walk(node.init)) ]

  FunctionExpression: (node, ctx) ->
    params = @makeParams(node.params)

    expr = @indent (i) =>
      [ params, "->\n", @walk(node.body) ]

    if node._parenthesized
      [ "(", expr, @indent(), ")" ]
    else
      expr

  EmptyStatement: (node) ->
    [ ]

  SequenceExpression: (node) ->
    exprs = node.expressions.map (expr) =>
      [ @walk(expr), "\n" ]

    delimit(exprs, @indent())

  NewExpression: (node) ->
    callee = if node.callee?.type is 'Identifier'
      [ @walk(node.callee) ]
    else
      [ '(', @walk(node.callee), ')' ]

    args = if node.arguments?.length
      [ '(', @makeSequence(node.arguments), ')' ]
    else
      []

    [ "new ", callee, args ]

  WhileStatement: (node) ->
    [ "while ", @walk(node.test), "\n", @makeLoopBody(node.body) ]

  CoffeeLoopStatement: (node) ->
    [ "loop", "\n", @makeLoopBody(node.body) ]

  DoWhileStatement: (node) ->
    @indent =>
      breaker = @indent [ "break unless ", @walk(node.test), "\n" ]
      [ "loop", "\n", @walk(node.body), breaker ]

  BreakStatement: (node) ->
    [ "break\n" ]

  ContinueStatement: (node) ->
    [ "continue\n" ]

  DebuggerStatement: (node) ->
    [ "debugger\n" ]

  TryStatement: (node) ->
    # block, guardedHandlers, handlers [], finalizer
    _try = @indent => [ "try\n", @walk(node.block) ]
    _catch = prependAll(node.handlers.map(@walk), @indent())
    _finally = if node.finalizer?
      @indent (indent) => [ indent, "finally\n", @walk(node.finalizer) ]
    else
      []

    [ _try, _catch, _finally ]

  CatchClause: (node) ->
    @indent => [ "catch ", @walk(node.param), "\n", @walk(node.body) ]

  ThrowStatement: (node) ->
    [ "throw ", @walk(node.argument), "\n" ]

  # Ternary operator (`a ? b : c`)
  ConditionalExpression: (node) ->
    space [
      "if", @walk(node.test),
      "then", @walk(node.consequent),
      "else", @walk(node.alternate)
    ]

  # Increment (`a++`)
  UpdateExpression: (node) ->
    if node.prefix
      [ node.operator, @walk(node.argument) ]
    else
      [ @walk(node.argument), node.operator ]

  SwitchStatement: (node) ->
    body = @indent => @makeStatements(node, node.cases)
    item = @walk(node.discriminant)

    if node.discriminant.type is 'ConditionalExpression'
      item = [ "(", item, ")" ]

    [ "switch ", item, "\n", body ]

  # Custom node type for comma-separated expressions (`when a, b`)
  CoffeeListExpression: (node) ->
    @makeSequence(node.expressions)

  SwitchCase: (node) ->
    left = if node.test
      [ "when ", @walk(node.test) ]
    else
      [ "else" ]

    right = @indent => @makeStatements(node, node.consequent)

    [ left, "\n", right ]

  ForInStatement: (node) ->
    if node.left.type isnt 'VariableDeclaration'
      # @syntaxError node, "Using 'for..in' loops without 'var' can produce
      # unexpected results"
      # node.left.name += '_'
      id = @walk(node.left)
      propagator = {
        type: 'ExpressionStatement'
        expression: { type: 'CoffeeEscapedExpression', raw: "#{id} = #{id}" }
      }
      node.body.body = [ propagator ].concat(node.body.body)
    else
      id = @walk(node.left.declarations[0].id)

    body = @makeLoopBody(node.body)

    [ "for ", id, " of ", @walk(node.right), "\n", body ]

  makeLoopBody: (body) ->
    isBlock = body?.type is 'BlockStatement'
    if not body or (isBlock and body.body.length is 0)
      @indent => [ @indent(), "continue\n" ]
    else if isBlock
      @indent => @walk(body)
    else
      @indent => [ @indent(), @walk(body) ]

  CoffeeEscapedExpression: (node) ->
    [ '`', node.raw, '`' ]

  CoffeePrototypeExpression: (node) ->
    if node.computed
      [ @walk(node.object), '::[', @walk(node.property), ']' ]
    else
      [ @walk(node.object), '::', @walk(node.property) ]

  ###*
  # makeSequence():
  # Builds a comma-separated sequence of nodes.
  # TODO: turn this into a transformation
  ###

  makeSequence: (list) ->
    for arg, i in list
      isLast = i is (list.length-1)
      if not isLast
        if arg.type is "FunctionExpression"
          arg._parenthesized = true
        else if arg.type is "ObjectExpression"
          arg._braced = true

    commaDelimit(list.map(@walk))

  ###*
  # makeParams():
  # Builds parameters for a function list.
  ###

  makeParams: (params) ->
    if params.length
      [ '(', delimit(params.map(@walk), ', '), ') ']
    else
      []

  ###*
  # In a call expression, ensure that non-last function arguments get
  # parenthesized (eg, `setTimeout (-> x), 500`).
  ###

  parenthesizeArguments: (node) ->
    for arg, i in node.arguments
      isLast = i is (node.arguments.length-1)
      if arg.type is "FunctionExpression"
        if not isLast
          arg._parenthesized = true

# }}} -----------------------------------------------------------------------

###*
# Export for testing.
###

js2coffee.Builder = Builder

# vim:foldmethod=marker
