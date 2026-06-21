# -*- coding: utf-8 -*-
#
#       speaker_notes.py
#
#       Copyright 2026 TeXSlide contributors
#
#       This program is free software; you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation; either version 2 of the License, or
#       (at your option) any later version.
#
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with this program; if not, write to the Free Software
#       Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#       MA 02110-1301, USA.
"""
:mod:`pympress.speaker_notes` -- Editable per-slide speaker notes (JSON sidecar)
-------------------------------------------------------------------------------

This module adds a text panel where the presenter can read (Presentation mode)
or edit (Rehearsal mode) free-form speaker notes for each slide. Notes are stored
in a JSON file living next to the PDF (``<document>.notes.json``), keyed by page
number. A lightweight fingerprint of the deck (page count + page labels) is saved
alongside the notes so that, if the deck is recompiled with slides added, removed
or reordered, we can warn the presenter that a note may have shifted rather than
silently showing it against the wrong slide.
"""

import logging
logger = logging.getLogger(__name__)

import os
import json
import hashlib

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import GLib  # noqa: E402

from pympress import builder


#: Marker written into the JSON so the format can evolve later.
NOTES_FORMAT = 'texslide-notes-v1'


class SpeakerNotes(builder.Builder):
    """ Manage the editable speaker-notes panel and its JSON sidecar.

    Args:
        builder (:class:`~pympress.builder.Builder`): The main UI builder, used to resolve callbacks.
    """
    #: :class:`~Gtk.Frame` containing the speaker-notes panel (the placeable widget).
    p_frame_speaker_notes = None
    #: :class:`~Gtk.ScrolledWindow` wrapping the text view.
    speaker_notes_scroll = None
    #: :class:`~Gtk.TextView` where notes are shown/edited.
    speaker_notes_view = None
    #: :class:`~Gtk.Label` shown when the deck changed under the notes.
    speaker_notes_warning = None

    def __init__(self, builder):
        super(SpeakerNotes, self).__init__()
        self.load_ui('speaker_notes')

        #: `dict` mapping a page index (as `str`) to its note text.
        self.notes = {}
        #: :class:`~pathlib.Path` of the JSON sidecar, or None when no document is open.
        self.path = None
        #: `dict` fingerprint of the deck the notes were last saved against.
        self.fingerprint = None
        #: `int` index of the page currently displayed, or None.
        self.current_page = None
        #: `bool` whether there are edits not yet written to disk.
        self.dirty = False
        #: `bool` whether the deck changed since the notes were written.
        self.shifted = False
        #: `bool` whether the last attempt to write the notes sidecar failed (e.g. read-only folder).
        self.save_error = False
        #: `bool` whether the panel is currently editable (Rehearsal mode).
        self.editable = False

        #: Guard to ignore the buffer ``changed`` signal while we set text programmatically.
        self._loading = False
        #: GLib source id of the pending debounced save, or None.
        self._save_source = None

        self.buffer = self.speaker_notes_view.get_buffer()
        self.buffer.connect('changed', self.on_buffer_changed)

        if self.speaker_notes_warning is not None:
            self.speaker_notes_warning.set_visible(False)
        self.set_editable(False)

    def set_editable(self, editable):
        """ Toggle between Presentation (read-only) and Rehearsal (editable) appearance.

        Args:
            editable (`bool`): `True` to allow editing (Rehearsal mode), `False` for read-only.
        """
        self.editable = editable
        view = self.speaker_notes_view
        view.set_editable(editable)
        view.set_cursor_visible(editable)
        # Only let the notes grab keyboard focus while editing, so that in Presentation mode
        # the navigation keys (arrows, space, …) are never swallowed by this text view.
        view.set_can_focus(editable)
        ctx = view.get_style_context()
        if editable:
            ctx.remove_class('speaker-notes-present')
            ctx.add_class('speaker-notes-rehearse')
        else:
            ctx.remove_class('speaker-notes-rehearse')
            ctx.add_class('speaker-notes-present')

    def load_notes(self, doc):
        """ Load the notes sidecar for a freshly-opened (or reloaded) document.

        Args:
            doc (:class:`~pympress.document.Document`): the document whose notes to load.
        """
        # Persist anything still pending from the previous document before switching.
        self.flush()

        self.notes = {}
        self.path = None
        self.fingerprint = None
        self.shifted = False
        self.save_error = False
        self.current_page = None

        path = getattr(doc, 'path', None)
        fingerprint = self._fingerprint(doc)

        if path is not None:
            try:
                path = path.resolve()
                self.path = path.parent.joinpath(path.stem + '.notes.json')
            except Exception:
                logger.exception('Could not derive speaker-notes path for document')
                self.path = None

        if self.path is not None and self.path.exists():
            try:
                with open(str(self.path), encoding='utf-8') as f:
                    data = json.load(f)
                self.notes = {str(k): str(v) for k, v in (data.get('notes') or {}).items()}
                stored = data.get('fingerprint')
                # Only warn if there actually are notes that could be misattached.
                self.shifted = bool(stored) and bool(self.notes) and stored != fingerprint
            except Exception:
                logger.exception('Could not read speaker notes from {}'.format(self.path))
                self.notes = {}
                self.shifted = False

        self.fingerprint = fingerprint
        self._update_warning()

    def _fingerprint(self, doc):
        """ Compute a small fingerprint of the deck to detect later structural changes.

        Args:
            doc (:class:`~pympress.document.Document`): the document to fingerprint.

        Returns:
            `dict`: with the page count and a hash of the page labels.
        """
        try:
            pages = doc.pages_number()
        except Exception:
            pages = 0

        labels = getattr(doc, 'page_labels', None)
        labels_hash = None
        if labels:
            try:
                joined = '\n'.join('' if lbl is None else str(lbl) for lbl in labels)
                labels_hash = hashlib.md5(joined.encode('utf-8')).hexdigest()
            except Exception:
                labels_hash = None

        return {'pages': pages, 'labels': labels_hash}

    def show_page(self, page):
        """ Display the note for `page`, committing the previously-shown page first.

        Args:
            page (`int`): the (preview) page index to show notes for.
        """
        self._commit_current()
        self.current_page = page
        text = self.notes.get(str(page), '') if page is not None else ''

        self._loading = True
        self.buffer.set_text(text)
        self._loading = False

    def on_buffer_changed(self, buffer):
        """ Handle edits in the text view: keep the model current and schedule a save.

        Args:
            buffer (:class:`~Gtk.TextBuffer`): the edited buffer.
        """
        if self._loading:
            return
        self._commit_current()
        self.dirty = True
        self._schedule_save()

    def _commit_current(self):
        """ Copy the current buffer contents into the in-memory notes model.
        """
        if self.current_page is None:
            return
        start, end = self.buffer.get_bounds()
        text = self.buffer.get_text(start, end, False)
        key = str(self.current_page)
        if text.strip():
            self.notes[key] = text
        elif key in self.notes:
            del self.notes[key]

    def _schedule_save(self, delay=600):
        """ Debounce writes to disk so we don't hit the filesystem on every keystroke.

        Args:
            delay (`int`): milliseconds to wait before writing.
        """
        if self._save_source is not None:
            GLib.source_remove(self._save_source)
        self._save_source = GLib.timeout_add(delay, self._save_timeout)

    def _save_timeout(self):
        self._save_source = None
        self.save_notes()
        return False

    def save_notes(self):
        """ Write the notes sidecar to disk atomically.
        """
        self._commit_current()
        if self.path is None:
            return
        # Don't create an empty file for documents that have no notes.
        if not self.notes and not self.path.exists():
            self.dirty = False
            return

        data = {
            'format': NOTES_FORMAT,
            'fingerprint': self.fingerprint or {},
            'notes': self.notes,
        }
        tmp = self.path.parent.joinpath(self.path.name + '.tmp')
        try:
            with open(str(tmp), 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
            os.replace(str(tmp), str(self.path))
            self.dirty = False
            if self.save_error:
                self.save_error = False
                self._update_warning()
        except Exception:
            logger.exception('Could not save speaker notes to {}'.format(self.path))
            try:
                if tmp.exists():
                    tmp.unlink()
            except Exception:
                pass
            # Surface the failure: notes stay in memory but the user must know they aren't on disk.
            if not self.save_error:
                self.save_error = True
                self._update_warning()

    def flush(self):
        """ Cancel any pending debounced save and write immediately if there are edits.
        """
        if self._save_source is not None:
            GLib.source_remove(self._save_source)
            self._save_source = None
        if self.dirty:
            self.save_notes()

    def _update_warning(self):
        """ Show or hide the warning banner (notes could not be saved, or the deck shifted).
        """
        if self.speaker_notes_warning is None:
            return
        if self.save_error:
            self.speaker_notes_warning.set_text(_(
                '⚠ These notes could not be saved — the PDF’s folder may be read-only. '
                'Move the PDF to a writable location (e.g. Documents) to keep your notes.'))
            self.speaker_notes_warning.set_visible(True)
        elif self.shifted:
            self.speaker_notes_warning.set_text(_(
                '⚠ The slides changed since these notes were written — a note may now be '
                'on the wrong slide. Please review.'))
            self.speaker_notes_warning.set_visible(True)
        else:
            self.speaker_notes_warning.set_visible(False)
