// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:ui/ui.dart' as ui;

import '../browser_detection.dart';
import '../dom.dart';
import '../platform_dispatcher.dart';
import '../safe_browser_api.dart';
import '../text_editing/text_editing.dart';
import 'semantics.dart';

/// Text editing used by accesibility mode.
///
/// [SemanticsTextEditingStrategy] assumes the caller will own the creation,
/// insertion and disposal of the DOM element. Due to this
/// [initializeElementPlacement], [initializeTextEditing] and
/// [disable] strategies are handled differently.
///
/// This class is still responsible for hooking up the DOM element with the
/// [HybridTextEditing] instance so that changes are communicated to Flutter.
class SemanticsTextEditingStrategy extends DefaultTextEditingStrategy {
  /// Creates a [SemanticsTextEditingStrategy] that eagerly instantiates
  /// [domElement] so the caller can insert it before calling
  /// [SemanticsTextEditingStrategy.enable].
  SemanticsTextEditingStrategy(super.owner);

  /// Initializes the [SemanticsTextEditingStrategy] singleton.
  ///
  /// This method must be called prior to accessing [instance].
  static SemanticsTextEditingStrategy ensureInitialized(HybridTextEditing owner) {
    if (_instance != null && instance.owner == owner) {
      return instance;
    }
    return _instance = SemanticsTextEditingStrategy(owner);
  }

  /// The [SemanticsTextEditingStrategy] singleton.
  static SemanticsTextEditingStrategy get instance => _instance!;
  static SemanticsTextEditingStrategy? _instance;

  /// The text field whose DOM element is currently used for editing.
  ///
  /// If this field is null, no editing takes place.
  TextField? activeTextField;

  /// Current input configuration supplied by the "flutter/textinput" channel.
  InputConfiguration? inputConfig;

  /// The semantics implementation does not operate on DOM nodes, but only
  /// remembers the config and callbacks. This is because the DOM nodes are
  /// supplied in the semantics update and enabled by [activate].
  @override
  void enable(
    InputConfiguration inputConfig, {
    required OnChangeCallback onChange,
    required OnActionCallback onAction,
  }) {
    this.inputConfig = inputConfig;
    this.onChange = onChange;
    this.onAction = onAction;
  }

  /// Attaches the DOM element owned by [textField] to the text editing
  /// strategy.
  ///
  /// This method must be called after [enable] to name sure that [inputConfig],
  /// [onChange], and [onAction] are not null.
  void activate(TextField textField) {
    assert(
      inputConfig != null && onChange != null && onAction != null,
      '"enable" should be called before "enableFromSemantics" and initialize input configuration',
    );

    if (activeTextField == textField) {
      // The specified field is already active. Skip.
      return;
    } else if (activeTextField != null) {
      // Another text field is currently active. Deactivate it before switching.
      disable();
    }

    activeTextField = textField;
    domElement = textField.editableElement;
    _syncStyle();
    super.enable(inputConfig!, onChange: onChange!, onAction: onAction!);
  }

  /// Detaches the DOM element owned by [textField] from this text editing
  /// strategy.
  ///
  /// Typically at this point the element loses focus (blurs) and stops being
  /// used for editing.
  void deactivate(TextField textField) {
    if (activeTextField == textField) {
      disable();
    }
  }

  @override
  void disable() {
    // We don't want to remove the DOM element because the caller is responsible
    // for that. However we still want to stop editing, cleanup the handlers.
    if (!isEnabled) {
      return;
    }

    isEnabled = false;
    style = null;
    geometry = null;

    for (int i = 0; i < subscriptions.length; i++) {
      subscriptions[i].cancel();
    }
    subscriptions.clear();
    lastEditingState = null;

    // If the text element still has focus, remove focus from the editable
    // element to cause the on-screen keyboard, if any, to hide (e.g. on iOS,
    // Android).
    // Otherwise, the keyboard stays on screen even when the user navigates to
    // a different screen (e.g. by hitting the "back" button).
    domElement?.blur();
    domElement = null;
    activeTextField = null;
    _queuedStyle = null;
  }

  @override
  void addEventHandlers() {
    if (inputConfiguration.autofillGroup != null) {
      subscriptions
          .addAll(inputConfiguration.autofillGroup!.addInputEventListeners());
    }

    // Subscribe to text and selection changes.
    subscriptions.add(
        DomSubscription(activeDomElement, 'input', allowInterop(handleChange)));
    subscriptions.add(
        DomSubscription(activeDomElement, 'keydown',
            allowInterop(maybeSendAction)));
    subscriptions.add(
        DomSubscription(domDocument, 'selectionchange',
            allowInterop(handleChange)));
    preventDefaultForMouseEvents();
  }

  @override
  void initializeTextEditing(InputConfiguration inputConfig,
      {OnChangeCallback? onChange, OnActionCallback? onAction}) {
    isEnabled = true;
    inputConfiguration = inputConfig;
    onChange = onChange;
    onAction = onAction;
    applyConfiguration(inputConfig);
  }

  @override
  void placeElement() {
    // If this text editing element is a part of an autofill group.
    if (hasAutofillGroup) {
      placeForm();
    }
    activeDomElement.focus();
  }

  @override
  void initializeElementPlacement() {
    // Element placement is done by [TextField].
  }

  @override
  void placeForm() {
  }

  @override
  void updateElementPlacement(EditableTextGeometry textGeometry) {
    // Element placement is done by [TextField].
  }

  EditableTextStyle? _queuedStyle;

  @override
  void updateElementStyle(EditableTextStyle textStyle) {
    _queuedStyle = textStyle;
    _syncStyle();
  }

  /// Apply style to the element, if both style and element are available.
  ///
  /// Because style is supplied by the "flutter/textinput" channel and the DOM
  /// element is supplied by the semantics tree, the existence of both at the
  /// same time is not guaranteed.
  void _syncStyle() {
    if (_queuedStyle == null || domElement == null) {
      return;
    }
    super.updateElementStyle(_queuedStyle!);
  }
}

/// Manages semantics objects that represent editable text fields.
///
/// This role is implemented via a content-editable HTML element. This role does
/// not proactively switch modes depending on the current
/// [EngineSemanticsOwner.gestureMode]. However, in Chrome on Android it ignores
/// browser gestures when in pointer mode. In Safari on iOS touch events are
/// used to detect text box invocation. This is because Safari issues touch
/// events even when Voiceover is enabled.
class TextField extends RoleManager {
  TextField(SemanticsObject semanticsObject)
      : super(Role.textField, semanticsObject) {
    editableElement =
        semanticsObject.hasFlag(ui.SemanticsFlag.isMultiline)
            ? createDomHTMLTextAreaElement()
            : createDomHTMLInputElement();
    _setupDomElement();
  }

  /// The element used for editing, e.g. `<input>`, `<textarea>`.
  late final DomHTMLElement editableElement;

  void _setupDomElement() {
    // On iOS, even though the semantic text field is transparent, the cursor
    // and text highlighting are still visible. The cursor and text selection
    // are made invisible by CSS in [FlutterViewEmbedder.reset].
    // But there's one more case where iOS highlights text. That's when there's
    // and autocorrect suggestion. To disable that, we have to do the following:
    editableElement
      ..spellcheck = false
      ..setAttribute('autocorrect', 'off')
      ..setAttribute('autocomplete', 'off')
      ..setAttribute('data-semantics-role', 'text-field');

    editableElement.style
      ..position = 'absolute'
      // `top` and `left` are intentionally set to zero here.
      //
      // The text field would live inside a `<flt-semantics>` which should
      // already be positioned using semantics.rect.
      //
      // See also:
      //
      // * [SemanticsObject.recomputePositionAndSize], which sets the position
      //   and size of the parent `<flt-semantics>` element.
      ..top = '0'
      ..left = '0'
      ..width = '${semanticsObject.rect!.width}px'
      ..height = '${semanticsObject.rect!.height}px';
    semanticsObject.element.append(editableElement);

    switch (browserEngine) {
      case BrowserEngine.blink:
      case BrowserEngine.firefox:
        _initializeForBlink();
        break;
      case BrowserEngine.webkit:
        _initializeForWebkit();
        break;
    }
  }

  /// Chrome on Android reports text field activation as a "click" event.
  ///
  /// When in browser gesture mode, the focus is forwarded to the framework as
  /// a tap to initialize editing.
  void _initializeForBlink() {
    editableElement.addEventListener(
        'focus', allowInterop((DomEvent event) {
          if (semanticsObject.owner.gestureMode != GestureMode.browserGestures) {
            return;
          }

          EnginePlatformDispatcher.instance.invokeOnSemanticsAction(
              semanticsObject.id, ui.SemanticsAction.tap, null);
        }));
  }

  /// Safari on iOS reports text field activation via touch events.
  ///
  /// This emulates a tap recognizer to detect the activation. Because touch
  /// events are present regardless of whether accessibility is enabled or not,
  /// this mode is always enabled.
  void _initializeForWebkit() {
    // Safari for desktop is also initialized as the other browsers.
    if (operatingSystem == OperatingSystem.macOs) {
      _initializeForBlink();
      return;
    }
    num? lastPointerDownOffsetX;
    num? lastPointerDownOffsetY;

    editableElement.addEventListener('pointerdown',
        allowInterop((DomEvent event) {
          final DomPointerEvent pointerEvent = event as DomPointerEvent;
          lastPointerDownOffsetX = pointerEvent.clientX;
          lastPointerDownOffsetY = pointerEvent.clientY;
        }), true);

    editableElement.addEventListener(
        'pointerup', allowInterop((DomEvent event) {
      final DomPointerEvent pointerEvent = event as DomPointerEvent;

      if (lastPointerDownOffsetX != null) {
        assert(lastPointerDownOffsetY != null);
        final num deltaX = pointerEvent.clientX - lastPointerDownOffsetX!;
        final num deltaY = pointerEvent.clientY - lastPointerDownOffsetY!;

        // This should match the similar constant defined in:
        //
        // lib/src/gestures/constants.dart
        //
        // The value is pre-squared so we have to do less math at runtime.
        const double kTouchSlop = 18.0 * 18.0; // Logical pixels squared

        if (deltaX * deltaX + deltaY * deltaY < kTouchSlop) {
          // Recognize it as a tap that requires a keyboard.
          EnginePlatformDispatcher.instance.invokeOnSemanticsAction(
              semanticsObject.id, ui.SemanticsAction.tap, null);

          // We need to call focus for the following scenario:
          // 1. The virtial keyboard in iOS gets dismissed by the 'Done' button
          // located at the top right of the keyboard.
          // 2. The user tries to focus on the input field again, either by
          // VoiceOver or manually, but the keyboard does not show up.
          //
          // In this scenario, the Flutter framework does not send a semantic update,
          // so we need to call focus after detecting a tap to make sure that the
          // virtual keyboard will show.
          if (semanticsObject.hasFocus) {
            editableElement.focus();
          }
        }
      } else {
        assert(lastPointerDownOffsetY == null);
      }

      lastPointerDownOffsetX = null;
      lastPointerDownOffsetY = null;
    }), true);
  }

  bool _hasFocused = false;

  @override
  void update() {
    // The user is editing the semantic text field directly, so there's no need
    // to do any update here.
    if (semanticsObject.hasLabel) {
      editableElement.setAttribute(
        'aria-label',
        semanticsObject.label!,
      );
    } else {
      editableElement.removeAttribute('aria-label');
    }

    editableElement.style
      ..width = '${semanticsObject.rect!.width}px'
      ..height = '${semanticsObject.rect!.height}px';

    // Whether we should request that the browser shift focus to the editable
    // element, so that both the framework and the browser agree on what's
    // currently focused.
    bool needsDomFocusRequest = false;

    if (semanticsObject.hasFocus) {
      if (!_hasFocused) {
        _hasFocused = true;
        SemanticsTextEditingStrategy.instance.activate(this);
        needsDomFocusRequest = true;
      }
      if (domDocument.activeElement != editableElement) {
        needsDomFocusRequest = true;
      }
    } else if (_hasFocused) {
      SemanticsTextEditingStrategy.instance.deactivate(this);

      if (_hasFocused && domDocument.activeElement == editableElement) {
        // Unlike `editableElement.focus()` we don't need to schedule `blur`
        // post-update because `document.activeElement` implies that the
        // element is already attached to the DOM. If it's not, it can't
        // possibly be focused and therefore there's no need to blur.
        editableElement.blur();
      }
      _hasFocused = false;
    }

    if (needsDomFocusRequest) {
      // Schedule focus post-update to make sure the element is attached to
      // the document. Otherwise focus() has no effect.
      semanticsObject.owner.addOneTimePostUpdateCallback(() {
        if (domDocument.activeElement != editableElement) {
          editableElement.focus();
        }
      });
    }
  }

  @override
  void dispose() {
    editableElement.remove();
    SemanticsTextEditingStrategy.instance.deactivate(this);
  }
}
