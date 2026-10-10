"""The review window: what was found, what to keep, and erasing it.

Ported from the UI half of src/Clear-TempFolders.ps1. The structure is the same:
the scan runs in the background and a 100 ms timer drains its queue into the list,
capped per tick so a burst of matches cannot freeze the window.

Gtk.ColumnView replaces the WinForms ListView. The Windows edition groups rows
under "Folders" and "Temp files" headers; here the Type column says which is which
and the columns sort, which does the same job with far less machinery.
"""

from __future__ import annotations

import gi

gi.require_version('Gtk', '4.0')
from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Pango  # noqa: E402

from . import APP_ID, APP_NAME
from .dialogs import confirm, open_in_file_manager, show_message
from .formatting import (ELLIPSIS, format_byte_size, format_count, format_erase_summary,
                         format_row_type, format_selection_summary, selection_summary)
from .jobs import Done, Failure, FoundFiles, FoundFolder, Progress, Removed, Size
from .model import FILES_ROW, Row
from .remover import PERMANENT, TRASH, start_removal
from .scanner import start_scan

MESSAGES_PER_TICK = 500
TICK_MILLISECONDS = 100

TRASH_NOTE = 'Space is freed when you empty the Trash.'
PERMANENT_NOTE = 'Erased items cannot be recovered.'


class RowObject(GObject.Object):
    """A Row, wrapped so Gtk.ColumnView can hold it."""

    __gtype_name__ = 'TempFileEraserRow'

    def __init__(self, row: Row):
        super().__init__()
        self.row = row

    @GObject.Property(type=bool, default=False)
    def checked(self) -> bool:
        return self.row.checked

    @checked.setter
    def checked(self, value: bool) -> None:
        self.row.checked = bool(value)

    @GObject.Property(type=str)
    def size_text(self) -> str:
        if self.row.bytes is None:
            return f'Calculating{ELLIPSIS}'
        return format_byte_size(self.row.bytes)


class ReviewWindow(Gtk.ApplicationWindow):
    def __init__(self, application: Gtk.Application, root: str):
        super().__init__(application=application, title=APP_NAME)
        self.root = str(root)
        self.phase = 'Scanning'
        self.job = None
        self.rows: dict[int, RowObject] = {}
        self.results: list[Removed] = []
        self.errors: list[str] = []
        self.mode = TRASH
        self._bindings: dict[Gtk.ListItem, list] = {}
        self._updating = False

        self.set_default_size(980, 620)
        self.set_child(self._build())
        self.connect('close-request', self._on_close_request)

        self.job = start_scan(self.root)
        self._tick = GLib.timeout_add(TICK_MILLISECONDS, self._pump)

    # ------------------------------------------------------------------ layout

    def _build(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(12)
        box.set_margin_bottom(6)
        box.set_margin_start(12)
        box.set_margin_end(12)

        self.header = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE)
        self._set_header(f'Scanning {self.root}{ELLIPSIS}')
        box.append(self.header)

        self.select_all = Gtk.CheckButton(label='Select all')
        self.select_all.connect('toggled', self._on_select_all)
        box.append(self.select_all)

        scroller = Gtk.ScrolledWindow(vexpand=True)
        scroller.set_child(self._build_list())
        box.append(scroller)

        self.total = Gtk.Label(xalign=0)
        self.total.set_markup('<b>Selected 0 of 0 items</b>')
        box.append(self.total)

        box.append(self._build_options())
        box.append(self._build_buttons())
        box.append(self._build_status())
        return box

    def _build_list(self) -> Gtk.Widget:
        self.store = Gio.ListStore(item_type=RowObject)
        self.sorted = Gtk.SortListModel(model=self.store)
        self.view = Gtk.ColumnView(model=Gtk.NoSelection(model=self.sorted))
        self.view.set_show_row_separators(True)
        self.sorted.set_sorter(self.view.get_sorter())

        self.view.append_column(self._check_column())
        self.view.append_column(self._text_column(
            'Folder', lambda obj: obj.row.path, expand=True,
            key=lambda obj: obj.row.path, ellipsize=Pango.EllipsizeMode.MIDDLE,
            context_menu=True))
        self.view.append_column(self._text_column(
            'Type', lambda obj: format_row_type(obj.row),
            key=lambda obj: format_row_type(obj.row)))
        self.view.append_column(self._text_column(
            'Size', None, bind_property='size-text', xalign=1,
            key=lambda obj: -1 if obj.row.bytes is None else obj.row.bytes))
        return self.view

    def _check_column(self) -> Gtk.ColumnViewColumn:
        factory = Gtk.SignalListItemFactory()

        def setup(_factory, item: Gtk.ListItem) -> None:
            check = Gtk.CheckButton()
            check.connect('toggled', lambda *_: self._on_row_toggled())
            item.set_child(check)

        def bind(_factory, item: Gtk.ListItem) -> None:
            check = item.get_child()
            obj = item.get_item()
            check.set_sensitive(self.phase != 'Erasing')
            self._bindings[item] = [obj.bind_property(
                'checked', check, 'active',
                GObject.BindingFlags.SYNC_CREATE | GObject.BindingFlags.BIDIRECTIONAL)]

        factory.connect('setup', setup)
        factory.connect('bind', bind)
        factory.connect('unbind', self._unbind)
        column = Gtk.ColumnViewColumn(factory=factory)
        column.set_fixed_width(42)
        return column

    def _text_column(self, title, getter, *, bind_property=None, key=None, expand=False,
                     xalign=0.0, ellipsize=Pango.EllipsizeMode.NONE,
                     context_menu=False) -> Gtk.ColumnViewColumn:
        factory = Gtk.SignalListItemFactory()

        def setup(_factory, item: Gtk.ListItem) -> None:
            label = Gtk.Label(xalign=xalign, ellipsize=ellipsize)
            if context_menu:
                gesture = Gtk.GestureClick(button=3)
                gesture.connect('pressed', self._on_right_click, item)
                label.add_controller(gesture)
            item.set_child(label)

        def bind(_factory, item: Gtk.ListItem) -> None:
            label = item.get_child()
            obj = item.get_item()
            if bind_property:
                self._bindings[item] = [obj.bind_property(
                    bind_property, label, 'label', GObject.BindingFlags.SYNC_CREATE)]
            else:
                label.set_text(getter(obj))
                label.set_tooltip_text(self._tooltip(obj.row))
            label.set_sensitive(obj.row.confidence == 'Certain')

        factory.connect('setup', setup)
        factory.connect('bind', bind)
        factory.connect('unbind', self._unbind)

        column = Gtk.ColumnViewColumn(title=title, factory=factory, expand=expand)
        if key is not None:
            column.set_sorter(Gtk.CustomSorter.new(_compare_by(key)))
        return column

    def _unbind(self, _factory, item: Gtk.ListItem) -> None:
        for binding in self._bindings.pop(item, ()):
            binding.unbind()

    @staticmethod
    def _tooltip(row: Row) -> str:
        if row.kind == FILES_ROW:
            return 'Files in this folder:\n' + '\n'.join(row.files)
        return row.path

    def _build_options(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.trash = Gtk.CheckButton(label='Move to Trash', active=True)
        self.permanent = Gtk.CheckButton(label='Erase permanently')
        self.permanent.set_group(self.trash)
        self.permanent.connect('toggled', self._on_mode_changed)
        self.mode_note = Gtk.Label(label=TRASH_NOTE, xalign=0)
        self.mode_note.add_css_class('dim-label')
        for widget in (self.trash, self.permanent, self.mode_note):
            box.append(widget)
        return box

    def _build_buttons(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, halign=Gtk.Align.END)
        self.stop = Gtk.Button(label='Stop scan')
        self.stop.connect('clicked', self._on_stop)
        self.cancel = Gtk.Button(label='Cancel')
        self.cancel.connect('clicked', lambda *_: self.close())
        self.erase = Gtk.Button(label='Erase', sensitive=False)
        self.erase.add_css_class('destructive-action')
        self.erase.connect('clicked', self._on_erase)
        for button in (self.stop, self.cancel, self.erase):
            box.append(button)
        return box

    def _build_status(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.status = Gtk.Label(label='Starting scan', xalign=0, hexpand=True,
                                ellipsize=Pango.EllipsizeMode.MIDDLE)
        self.status.add_css_class('dim-label')
        self.progress = Gtk.ProgressBar(valign=Gtk.Align.CENTER, visible=False)
        box.append(self.status)
        box.append(self.progress)
        return box

    def _set_header(self, text: str) -> None:
        self.header.set_markup(f'<b>{GLib.markup_escape_text(text)}</b>')

    # ------------------------------------------------------------------- events

    def _on_right_click(self, gesture: Gtk.GestureClick, _n, x, y, item: Gtk.ListItem) -> None:
        obj = item.get_item()
        if obj is None:
            return
        menu = Gio.Menu()
        menu.append('Open in file manager', 'win.open-row')
        pointing_to = Gdk.Rectangle()
        pointing_to.x, pointing_to.y, pointing_to.width, pointing_to.height = int(x), int(y), 1, 1

        popover = Gtk.PopoverMenu.new_from_model(menu)
        popover.set_parent(gesture.get_widget())
        popover.set_pointing_to(pointing_to)
        popover.connect('closed', lambda widget: widget.unparent())
        self._menu_target = obj.row
        popover.popup()

    def _on_select_all(self, button: Gtk.CheckButton) -> None:
        if self._updating or self.phase == 'Erasing':
            return
        wanted = button.get_active()
        self._updating = True
        try:
            for index in range(self.store.get_n_items()):
                self.store.get_item(index).set_property('checked', wanted)
        finally:
            self._updating = False
        self._update_totals()

    def _on_row_toggled(self) -> None:
        if not self._updating:
            self._update_totals()

    def _on_mode_changed(self, _button) -> None:
        permanent = self.permanent.get_active()
        self.mode_note.set_text(PERMANENT_NOTE if permanent else TRASH_NOTE)

    def _on_stop(self, _button) -> None:
        if self.job:
            self.job.cancel.set()
        self.stop.set_sensitive(False)
        self.status.set_text(f'Stopping{ELLIPSIS}')

    def _on_close_request(self, _window) -> bool:
        if self.phase == 'Erasing':
            return True          # never leave a half-finished removal behind
        self._stop_tick()
        if self.job:
            self.job.stop()
            self.job = None
        return False

    def _stop_tick(self) -> None:
        if self._tick:
            GLib.source_remove(self._tick)
            self._tick = 0

    # -------------------------------------------------------------------- pump

    def _pump(self) -> bool:
        job = self.job
        if job is None:
            return GLib.SOURCE_REMOVE

        done = None
        messages = job.drain(MESSAGES_PER_TICK)
        for message in messages:
            if isinstance(message, (FoundFolder, FoundFiles)):
                self._add_row(message)
            elif isinstance(message, Size):
                self._apply_size(message)
            elif isinstance(message, Progress):
                self._apply_progress(message)
            elif isinstance(message, Removed):
                self.results.append(message)
            elif isinstance(message, Failure):
                self.errors.append(message.message)
            elif isinstance(message, Done):
                done = message
                break

        if messages and self.phase != 'Erasing':
            self._update_totals()
        if done is not None:
            job.stop()
            self.job = None
            self._tick = 0      # returning SOURCE_REMOVE below already drops the timer
            if self.phase == 'Scanning':
                self._complete_scan(done.cancelled)
            else:
                self._complete_erase()
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE

    def _add_row(self, message) -> None:
        obj = RowObject(Row.from_message(message))
        self.rows[message.id] = obj
        self.store.append(obj)

    def _apply_size(self, message: Size) -> None:
        obj = self.rows.get(message.id)
        if obj is not None:
            obj.row.bytes = message.bytes
            obj.notify('size-text')

    def _apply_progress(self, message: Progress) -> None:
        self.status.set_text(message.text)
        if message.step is not None and message.steps:
            self.progress.set_fraction((message.step - 1) / message.steps)

    def _update_totals(self) -> None:
        rows = [self.store.get_item(i).row for i in range(self.store.get_n_items())]
        summary = selection_summary(rows)
        text = format_selection_summary(summary, still_scanning=self.phase == 'Scanning')
        self.total.set_markup(f'<b>{GLib.markup_escape_text(text)}</b>')

        self._updating = True
        try:
            self.select_all.set_inconsistent(0 < summary.selected < summary.total)
            self.select_all.set_active(summary.selected == summary.total and summary.total > 0)
        finally:
            self._updating = False
        self.erase.set_sensitive(self.phase == 'Ready' and summary.selected > 0)

    # --------------------------------------------------------------- completion

    def _complete_scan(self, cancelled: bool) -> None:
        for index in range(self.store.get_n_items()):
            obj = self.store.get_item(index)
            if obj.row.bytes is None:
                obj.row.bytes = 0
                obj.notify('size-text')

        if self.store.get_n_items() == 0:
            self.phase = 'Finished'
            text = (f'Scan stopped before anything was found in:\n{self.root}' if cancelled
                    else f'No temp, cache or build folders or files were found in:\n{self.root}')
            for message in self.errors:
                text += f'\n\nError: {message}'
            show_message(text, 'information', self, on_close=self.close)
            return

        self.phase = 'Ready'
        self.stop.set_visible(False)
        self._set_header(f'Found {format_count(self.store.get_n_items(), "item")} in {self.root}')
        if self.errors:
            self.status.set_text(f'Scan ended with an error: {self.errors[0]}')
        elif cancelled:
            self.status.set_text('Scan stopped. Items found so far are listed; '
                                 'some sizes are unknown.')
        else:
            self.status.set_text('Scan complete. Uncheck anything you want to keep, '
                                 'then choose Erase.')
        self._update_totals()

    def _on_erase(self, _button) -> None:
        rows = [self.store.get_item(i).row for i in range(self.store.get_n_items())
                if self.store.get_item(i).row.checked]
        if not rows:
            return

        mode = PERMANENT if self.permanent.get_active() else TRASH
        if mode == PERMANENT:
            summary = selection_summary(rows)
            question = (f'Permanently erase {format_count(len(rows), "item")} '
                        f'({format_byte_size(summary.bytes)})?\n'
                        'They will not go to the Trash. This cannot be undone.')
            confirm(question, lambda accepted: accepted and self._start_erase(rows, mode),
                    parent=self)
            return
        self._start_erase(rows, mode)

    def _start_erase(self, rows: list[Row], mode: str) -> None:
        self.mode = mode
        self.phase = 'Erasing'
        for widget in (self.view, self.select_all, self.trash, self.permanent,
                       self.erase, self.cancel):
            widget.set_sensitive(False)
        self._set_header(f'Removing {format_count(len(rows), "item")}{ELLIPSIS}')
        self.progress.set_fraction(0)
        self.progress.set_visible(True)

        self.job = start_removal([row.to_item() for row in rows], mode)
        self._tick = GLib.timeout_add(TICK_MILLISECONDS, self._pump)

    def _complete_erase(self) -> None:
        self.phase = 'Finished'
        self.progress.set_fraction(1)
        summary = format_erase_summary(self.results, self.mode, self.errors)
        show_message(summary.text, summary.icon, self, on_close=self.close)


def _compare_by(key):
    def compare(left, right, _user_data=None) -> int:
        a, b = key(left), key(right)
        return (a > b) - (a < b)
    return compare


class EraserApplication(Gtk.Application):
    def __init__(self, root: str):
        # NON_UNIQUE: right-clicking two folders must open two windows
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.root = root

    def do_activate(self) -> None:
        window = ReviewWindow(self, self.root)
        action = Gio.SimpleAction.new('open-row', None)
        action.connect('activate', lambda *_: open_in_file_manager(
            getattr(window, '_menu_target', None).path))
        window.add_action(action)
        window.present()


def run(root) -> int:
    return EraserApplication(str(root)).run([])
