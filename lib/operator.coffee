LineEndingRegExp = /(?:\n|\r\n)$/
_ = require 'underscore-plus'
{Point, Range, Disposable} = require 'atom'

{inspect} = require 'util'
{
  haveSomeSelection
  highlightRanges
  isEndsWithNewLineForBufferRow
  getValidVimBufferRow
  cursorIsAtEmptyRow
  scanInRanges
  getVisibleBufferRange
  getWordPatternAtBufferPosition

  selectedRange
  selectedText
  toString
  debug
} = require './utils'
swrap = require './selection-wrapper'
settings = require './settings'
Base = require './base'
CursorPositionManager = require './cursor-position-manager'

class Operator extends Base
  @extend(false)
  requireTarget: true
  recordable: true

  wise: null
  occurrence: false

  patternForOccurrence: null
  stayOnLinewise: false
  stayAtSamePosition: null
  clipToMutationEndOnStay: true
  useMarkerForStay: false
  restorePositions: true
  restorePositionsToMutationEnd: false
  flashTarget: true
  trackChange: false
  acceptPresetOccurrence: true
  acceptPersistentSelection: true

  # [FIXME]
  # For TextObject, isLinewise result is changed before / after select.
  # This mean return value may change depending on when you call.
  needStay: ->
    @stayAtSamePosition ?= do =>
      param = @getStayParam()
      if @isMode('visual', 'linewise')
        settings.get(param)
      else
        settings.get(param) or (@stayOnLinewise and @target.isLinewise?())

  getStayParam: ->
    switch
      when @instanceof('Increase')
        'stayOnIncrease'
      when @instanceof('TransformString')
        'stayOnTransformString'
      when @instanceof('Delete')
        'stayOnDelete'
      else
        "stayOn#{@getName()}"

  isOccurrence: ->
    @occurrence

  setMarkForChange: (range) ->
    @vimState.mark.setRange('[', ']', range)

  needFlash: ->
    if @flashTarget and not @isMode('visual')
      settings.get('flashOnOperate') and (@getName() not in settings.get('flashOnOperateBlacklist'))

  flashIfNecessary: (ranges) ->
    return unless @needFlash()

    highlightRanges @editor, ranges,
      class: 'vim-mode-plus-flash'
      timeout: settings.get('flashOnOperateDuration')

  flashChangeIfNecessary: ->
    return unless @needFlash()

    @onDidFinishOperation =>
      ranges = @mutationTracker.getMarkerBufferRanges().filter (range) -> not range.isEmpty()
      if ranges.length
        @flashIfNecessary(ranges)

  trackChangeIfNecessary: ->
    return unless @trackChange

    @onDidFinishOperation =>
      if marker = @mutationTracker.getMutationForSelection(@editor.getLastSelection()).marker
        @setMarkForChange(marker.getBufferRange())

  constructor: ->
    super
    {@mutationTracker, @occurrenceManager} = @vimState

    @initialize()

    @onDidSetOperatorModifier ({occurrence, wise}) =>
      @wise = wise if wise?
      @setOccurrence('modifier') if occurrence?

    @target ?= implicitTarget if implicitTarget = @getImplicitTarget()

    if _.isString(@target)
      @setTarget(@new(@target))

    # When preset-occurrence was exists, auto enable occurrence-wise
    if @occurrence
      @setOccurrence('static')
    else if @acceptPresetOccurrence and @occurrenceManager.hasPatterns()
      @setOccurrence('preset')

  getImplicitTarget: ->
    canSelectPersistentSelection =
      @vimState.hasPersistentSelections() and
        @acceptPersistentSelection and
        settings.get('autoSetPersistentSelectionAsTarget')

    # In visual-mode and target was not pre-set, operate on selected area.
    if @isMode('visual')
      if canSelectPersistentSelection
        "ACurrentSelectionAndAPersistentSelection"
      else
        "CurrentSelection"
    else
      "APersistentSelection" if canSelectPersistentSelection

  # type is one of ['preset', 'modifier']
  setOccurrence: (type) ->
    @addToClassList('with-occurrence')
    @occurrence = true
    switch type
      when 'static'
        unless @isComplete() # we enter operator-pending
          debug 'static: mark as we enter operator-pending'
          @addToClassList('with-occurrence')
          @addOccurrencePattern() unless @hasOccurrenceMarkers()
      when 'preset'
        debug 'preset: nothing to do since we have markers already'
        @addToClassList('with-occurrence')
      when 'modifier'
        debug 'modifier: overwrite existing marker when manually typed `o`'
        @resetOccurrencePatterns() # clear existing marker
        @addOccurrencePattern() # mark cursor word.

  hasOccurrenceMarkers: ->
    @occurrenceManager.hasMarkers()

  addOccurrencePattern: (pattern=null) ->
    pattern ?= @patternForOccurrence
    unless pattern?
      point = @getCursorBufferPosition()
      pattern = getWordPatternAtBufferPosition(@editor, point, singleNonWordChar: true)
    @occurrenceManager.addPattern(pattern)

  resetOccurrencePatterns: ->
    @occurrenceManager.resetPatterns() # clear existing marker

  # target is TextObject or Motion to operate on.
  setTarget: (@target) ->
    @target.setOperator(this)
    @emitDidSetTarget(this)
    this

  forceTargetWise: ->
    switch @wise
      when 'characterwise'
        if @target.linewise
          @target.linewise = false
          @target.inclusive = false
        else
          @target.inclusive = not @target.inclusive
      when 'linewise'
        @target.linewise = true

  setTextToRegisterForSelection: (selection) ->
    @setTextToRegister(selection.getText(), selection)

  setTextToRegister: (text, selection) ->
    text += "\n" if (@target.isLinewise?() and (not text.endsWith('\n')))
    @vimState.register.set({text, selection}) if text

  # Main
  execute: ->
    canMutate = true
    stopMutation = -> canMutate = false
    if @selectTarget()
      @editor.transact =>
        for selection in @editor.getSelections() when canMutate
          @mutateSelection(selection, stopMutation)
      @restoreCursorPositionsIfNecessary()

    # Even though we fail to select target and fail to mutate,
    # we have to return to normal-mode from operator-pending or visual
    @activateMode('normal')

  reselectOccurrence: (fn) ->
    cursorPositionManager = new CursorPositionManager(@editor)
    cursorPositionManager.save('head', fromProperty: true, allowFallback: true)

    # This has to be BEFORE @target.select, to use CURRENT cursor position.
    # to find occurrence-word.
    @addOccurrencePattern() unless @hasOccurrenceMarkers()

    fn()

    @addOccurrencePattern() unless @hasOccurrenceMarkers()
    scanRanges = @editor.getSelectedBufferRanges()
    isVisual = @isMode('visual')
    @vimState.modeManager.deactivate() if isVisual
    
    if @occurrenceManager.selectInRanges(scanRanges, isVisual)
      cursorPositionManager.destroy()
    else
      # Restoring cursor position also clear selection. Require to avoid unwanted mutation.
      cursorPositionManager.restore()

    # There is possibility that multiple markers are pre-setted manually.
    # To repeat this multi pre-set occurrences by `.`, we consult manager to cache
    # bundled(unioned) regex pattern to @patternForOccurrence.
    @patternForOccurrence ?= @occurrenceManager.buildPattern()
    # We got ranges to select, so good-by @occurrenceManager by reset()
    @occurrenceManager.resetPatterns()

  # Return true unless all selection is empty.
  selectTarget: ->
    @mutationTracker.start(
      stay: @needStay()
      isSelect: @instanceof('Select')
      useMarker: @useMarkerForStay
    )
    @mutationTracker.setCheckPoint('will-select')

    @forceTargetWise() if @wise
    @emitWillSelectTarget()

    if @isOccurrence()
      @reselectOccurrence =>
        @target.select()
    else
      @target.select()

    if haveSomeSelection(@editor)
      @mutationTracker.setCheckPoint('did-select')
      @emitDidSelectTarget()
      @flashChangeIfNecessary()
      @trackChangeIfNecessary()
    haveSomeSelection(@editor)

  restoreCursorPositionsIfNecessary: ->
    return unless @restorePositions
    options =
      strict: @isOccurrence()
      clipToMutationEnd: @clipToMutationEndOnStay
      isBlockwise: @target?.isBlockwise?()
      mutationEnd: @restorePositionsToMutationEnd
    @mutationTracker.restoreCursorPositions(options)
    @emitDidRestoreCursorPositions()

# Select
# When text-object is invoked from normal or viusal-mode, operation would be
#  => Select operator with target=text-object
# When motion is invoked from visual-mode, operation would be
#  => Select operator with target=motion)
# ================================
class Select extends Operator
  @extend(false)
  flashTarget: false
  recordable: false
  acceptPresetOccurrence: false

  canChangeMode: ->
    if @isMode('visual')
      @isOccurrence() or @target.isAllowSubmodeChange?()
    else
      true

  execute: ->
    @selectTarget()
    if @canChangeMode()
      submode = swrap.detectVisualModeSubmode(@editor)
      @activateModeIfNecessary('visual', submode)

class SelectLatestChange extends Select
  @extend()
  @description: "Select latest yanked or changed range"
  target: 'ALatestChange'

class SelectPreviousSelection extends Select
  @extend()
  target: "PreviousSelection"
  execute: ->
    @selectTarget()
    if @target.submode?
      @activateModeIfNecessary('visual', @target.submode)

class SelectPersistentSelection extends Select
  @extend()
  @description: "Select persistent-selection and clear all persistent-selection, it's like convert to real-selection"
  target: "APersistentSelection"

class SelectOccurrence extends Operator
  @extend()
  @description: "Add selection onto each matching word within target range"
  occurrence: true
  initialize: ->
    super
    @onDidSelectTarget =>
      swrap.clearProperties(@editor)

  execute: ->
    if @selectTarget()
      submode = swrap.detectVisualModeSubmode(@editor)
      @activateModeIfNecessary('visual', submode)

class SelectOccurrenceInAFunctionOrInnerParagraph extends SelectOccurrence
  @extend()
  target: "AFunctionOrInnerParagraph"

# Range Marker
# =========================
class CreatePersistentSelection extends Operator
  @extend()
  flashTarget: false
  stayAtSamePosition: true
  acceptPresetOccurrence: false
  acceptPersistentSelection: false

  mutateSelection: (selection) ->
    @vimState.persistentSelection.markBufferRange(selection.getBufferRange())

class TogglePersistentSelection extends CreatePersistentSelection
  @extend()
  isComplete: ->
    point = @editor.getCursorBufferPosition()
    if @markerToRemove = @vimState.persistentSelection.getMarkerAtPoint(point)
      true
    else
      super

  execute: ->
    if @markerToRemove
      @markerToRemove.destroy()
    else
      super

class TogglePersistentSelectionOnInnerWord extends TogglePersistentSelection
  @extend()
  target: 'InnerWord'

# Preset Occurrence
# =========================
class PresetOccurrence extends Operator
  @extend()
  flashTarget: false
  requireTarget: false
  stayAtSamePosition: true
  acceptPresetOccurrence: false

  execute: ->
    {@occurrenceManager} = @vimState
    if marker = @occurrenceManager.getMarkerAtPoint(@editor.getCursorBufferPosition())
      marker.destroy()
    else
      pattern = null
      isNarrowed = @vimState.modeManager.isNarrowed()
      if @isMode('visual') and not isNarrowed
        text = @editor.getSelectedText()
        pattern = new RegExp(_.escapeRegExp(text), 'g')

      @addOccurrencePattern(pattern)
      @activateMode('normal') unless isNarrowed

# Delete
# ================================
class Delete extends Operator
  @extend()
  hover: icon: ':delete:', emoji: ':scissors:'
  trackChange: true
  flashTarget: false

  execute: ->
    @onDidSelectTarget =>
      @requestAdjustCursorPositions() if @target.isLinewise()
    super

  mutateSelection: (selection) =>
    @setTextToRegisterForSelection(selection)
    selection.deleteSelectedText()

  requestAdjustCursorPositions: ->
    @onDidRestoreCursorPositions =>
      for cursor in @editor.getCursors()
        @adjustCursor(cursor)

  adjustCursor: (cursor) ->
    row = getValidVimBufferRow(@editor, cursor.getBufferRow())
    if @needStay()
      point = @mutationTracker.getInitialPointForSelection(cursor.selection)
      cursor.setBufferPosition([row, point.column])
    else
      cursor.setBufferPosition([row, 0])
      cursor.skipLeadingWhitespace()

class DeleteRight extends Delete
  @extend()
  target: 'MoveRight'
  hover: null

class DeleteLeft extends Delete
  @extend()
  target: 'MoveLeft'

class DeleteToLastCharacterOfLine extends Delete
  @extend()
  target: 'MoveToLastCharacterOfLine'
  execute: ->
    # Ensure all selections to un-reversed
    if @isMode('visual', 'blockwise')
      swrap.setReversedState(@editor, false)
    super

class DeleteLine extends Delete
  @extend()
  @commandScope: 'atom-text-editor.vim-mode-plus.visual-mode'
  execute: ->
    @vimState.activate('visual', 'linewise')
    super

class DeleteOccurrenceInAFunctionOrInnerParagraph extends Delete
  @extend()
  occurrence: true
  target: "AFunctionOrInnerParagraph"

# Yank
# =========================
class Yank extends Operator
  @extend()
  hover: icon: ':yank:', emoji: ':clipboard:'
  trackChange: true
  stayOnLinewise: true

  mutateSelection: (selection) ->
    @setTextToRegisterForSelection(selection)

class YankLine extends Yank
  @extend()
  target: 'MoveToRelativeLine'

  execute: ->
    if @isMode('visual')
      unless @isMode('visual', 'linewise')
        @vimState.modeManager.activate('visual', 'linewise')
    super

class YankToLastCharacterOfLine extends Yank
  @extend()
  target: 'MoveToLastCharacterOfLine'

# -------------------------
# [FIXME?]: inconsistent behavior from normal operator
# Since its support visual-mode but not use setTarget() convension.
# Maybe separating complete/in-complete version like IncreaseNow and Increase?
class Increase extends Operator
  @extend()
  requireTarget: false
  step: 1

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g

    newRanges = []
    @editor.transact =>
      for cursor in @editor.getCursors()
        scanRange = if @isMode('visual')
          cursor.selection.getBufferRange()
        else
          cursor.getCurrentLineBufferRange()
        ranges = @increaseNumber(cursor, scanRange, pattern)
        if not @isMode('visual') and ranges.length
          cursor.setBufferPosition ranges[0].end.translate([0, -1])
        newRanges.push ranges

    if (newRanges = _.flatten(newRanges)).length
      @flashIfNecessary(newRanges)
    else
      atom.beep()

  increaseNumber: (cursor, scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, range, stop, replace}) =>
      newText = String(parseInt(matchText, 10) + @step * @getCount())
      if @isMode('visual')
        newRanges.push replace(newText)
      else
        return unless range.end.isGreaterThan cursor.getBufferPosition()
        newRanges.push replace(newText)
        stop()
    newRanges

class Decrease extends Increase
  @extend()
  step: -1

# -------------------------
class IncrementNumber extends Operator
  @extend()
  displayName: 'Increment ++'
  step: 1
  baseNumber: null

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g
    newRanges = null
    @selectTarget()
    @editor.transact =>
      newRanges = for selection in @editor.getSelectionsOrderedByBufferPosition()
        @replaceNumber(selection.getBufferRange(), pattern)
    if (newRanges = _.flatten(newRanges)).length
      @flashIfNecessary(newRanges)
    else
      atom.beep()
    for selection in @editor.getSelections()
      selection.cursor.setBufferPosition(selection.getBufferRange().start)
    @activateModeIfNecessary('normal')

  replaceNumber: (scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, replace}) =>
      newRanges.push replace(@getNewText(matchText))
    newRanges

  getNewText: (text) ->
    @baseNumber = if @baseNumber?
      @baseNumber + @step * @getCount()
    else
      parseInt(text, 10)
    String(@baseNumber)

class DecrementNumber extends IncrementNumber
  @extend()
  displayName: 'Decrement --'
  step: -1

# Put
# -------------------------
class PutBefore extends Operator
  @extend()
  requireTarget: false
  location: 'before'

  execute: ->
    @editor.transact =>
      for selection in @editor.getSelections()
        {cursor} = selection
        {text, type} = @vimState.register.get(null, selection)
        break unless text
        text = _.multiplyString(text, @getCount())
        newRange = @paste selection, text,
          linewise: (type is 'linewise') or @isMode('visual', 'linewise')
          select: @selectPastedText
        @setMarkForChange(newRange)
        @flashIfNecessary(newRange)

    if @selectPastedText
      @activateModeIfNecessary('visual', swrap.detectVisualModeSubmode(@editor))
    else
      @activateMode('normal')

  paste: (selection, text, {linewise, select}) ->
    {cursor} = selection
    select ?= false
    linewise ?= false
    if linewise
      newRange = @pasteLinewise(selection, text)
      adjustCursor = (range) ->
        cursor.setBufferPosition(range.start)
        cursor.moveToFirstCharacterOfLine()
    else
      newRange = @pasteCharacterwise(selection, text)
      adjustCursor = (range) ->
        cursor.setBufferPosition(range.end.translate([0, -1]))

    if select
      selection.setBufferRange(newRange)
    else
      adjustCursor(newRange)
    newRange

  # Return newRange
  pasteLinewise: (selection, text) ->
    {cursor} = selection
    text += "\n" unless text.endsWith("\n")
    if selection.isEmpty()
      row = cursor.getBufferRow()
      switch @location
        when 'before'
          range = [[row, 0], [row, 0]]
        when 'after'
          unless isEndsWithNewLineForBufferRow(@editor, row)
            text = text.replace(LineEndingRegExp, '')
          cursor.moveToEndOfLine()
          {end} = selection.insertText("\n")
          range = @editor.bufferRangeForBufferRow(end.row, {includeNewline: true})
      @editor.setTextInBufferRange(range, text)
    else
      if @isMode('visual', 'linewise')
        unless selection.getBufferRange().end.column is 0
          text = text.replace(LineEndingRegExp, '')
      else
        selection.insertText("\n")
      selection.insertText(text)

  pasteCharacterwise: (selection, text) ->
    if @location is 'after' and selection.isEmpty() and not cursorIsAtEmptyRow(selection.cursor)
      selection.cursor.moveRight()
    selection.insertText(text)

class PutAfter extends PutBefore
  @extend()
  location: 'after'

class PutBeforeAndSelect extends PutBefore
  @extend()
  @description: "Paste before then select"
  selectPastedText: true

class PutAfterAndSelect extends PutAfter
  @extend()
  @description: "Paste after then select"
  selectPastedText: true
