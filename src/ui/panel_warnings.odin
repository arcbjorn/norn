package ui

import "core:fmt"

import "src:render"
import "src:trace/codec"

// The session warning panel.
//
// docs/01: "Warnings do not disappear after the import dialog. They remain part
// of the session metadata." The counts are written into the trace, but a user
// who opens one months later never saw the dialog — so the workspace has to
// carry them.
//
// This exists because a trace can be quietly incomplete. A third of its
// timestamps may have been repaired, or a hundred records dropped as malformed,
// and every panel would still render confidently. The warnings are what
// separate "the session did not do that" from "the import could not see it",
// and a user drawing conclusions needs to know which they are looking at.
//
// Each line therefore states the consequence, not the category name. A count
// beside `ambiguous_pairing` tells a user nothing; "12 tool results could not
// be matched to their calls" tells them which conclusions to distrust.

Warning_Theme :: struct {
	background: render.Color,
	border:     render.Color,
	heading:    render.Color,
	label:      render.Color,
	muted:      render.Color,
	// Warnings that limit what can be concluded, versus ones that only reduce
	// completeness. docs/01 requires status to carry in text as well as colour,
	// so the severity also changes the wording.
	serious: render.Color,
	notice:  render.Color,
}

DARK_WARNINGS :: Warning_Theme {
	background = render.Color{0.13, 0.12, 0.10, 1.0},
	border     = render.Color{0.35, 0.29, 0.18, 1.0},
	heading    = render.Color{0.95, 0.90, 0.80, 1.0},
	label      = render.Color{0.82, 0.80, 0.76, 1.0},
	muted      = render.Color{0.56, 0.54, 0.50, 1.0},
	serious    = render.Color{0.95, 0.55, 0.35, 1.0},
	notice     = render.Color{0.88, 0.74, 0.40, 1.0},
}

// Warning_State is what the panel needs to draw.
Warning_State :: struct {
	bounds: render.Rect,
	theme:  Warning_Theme,
	fonts:  ^render.Font_Set,
	atlas:  ^render.Atlas,
	heading_atlas: ^render.Atlas,
	scale:  f32,
	scroll: f32,
}

// Severity separates warnings that limit conclusions from ones that only
// reduce completeness.
//
// The distinction is not cosmetic. A repaired timestamp means the order shown
// is source order rather than clock order — a caveat. A failed patch means a
// file's content at that point is unknown — a hole in the evidence. Presenting
// both as "warnings" with equal weight would bury the second.
Severity :: enum u8 {
	Notice,
	Serious,
}

// warning_severity classifies a category by what it costs the user.
warning_severity :: proc "contextless" (category: codec.Warning_Category) -> Severity {
	#partial switch category {
	case .Patch_Failed, .Hash_Mismatch, .Missing_Baseline:
		// Replay could not reconstruct content. Conclusions about what a file
		// held at that moment are unavailable, not merely approximate.
		return .Serious
	case .Malformed_Record, .Path_Rejected:
		// Records the import could not use at all. Something happened in the
		// session that the trace does not contain.
		return .Serious
	}
	return .Notice
}

// warning_description states what a category means for the user's conclusions.
//
// Phrased as a consequence rather than a category, and in the plural form the
// count will precede. "3 records were malformed" reads; "3 malformed_record"
// does not.
warning_description :: proc "contextless" (category: codec.Warning_Category) -> string {
	switch category {
	case .Malformed_Record:
		return "records could not be parsed and are absent from this trace"
	case .Unsupported_Record:
		return "records were of a kind the importer does not map"
	case .Timestamp_Repaired:
		return "timestamps went backwards and were repaired to source order"
	case .Path_Rejected:
		return "paths were refused for escaping the repository"
	case .Content_Truncated:
		return "values were too large to store and were cut short"
	case .Patch_Failed:
		return "patches did not apply, leaving file content unknown"
	case .Hash_Mismatch:
		return "reconstructions disagreed with their recorded hash"
	case .Missing_Baseline:
		return "mutations had no baseline to apply against"
	case .Ambiguous_Pairing:
		return "tool results could not be matched to their calls"
	case .Span_Incomplete:
		return "operations never recorded an end"
	}
	return "unrecognised warnings"
}

// redaction_description names what a rule replaced.
redaction_description :: proc "contextless" (category: codec.Redaction_Category) -> string {
	switch category {
	case .Credential:           return "credential-shaped values"
	case .Authorization_Header: return "authorization headers"
	case .Environment_Variable: return "sensitive environment values"
	case .Url_User_Info:        return "credentials embedded in URLs"
	case .Home_Path_Prefix:     return "home-directory prefixes"
	case .User_Rule:            return "values matching your own rules"
	case .Provider_Sensitive:   return "provider-flagged fields"
	}
	return "values"
}

// WARNING_LINE_HEIGHT is the vertical step between lines, in logical pixels.
WARNING_LINE_HEIGHT :: f32(18)

// draw_warnings renders the session's import warnings and redactions.
//
// Returns the content height so the caller can bound scrolling. A panel that
// clipped without reporting its extent would strand the last lines out of
// reach.
draw_warnings :: proc(
	list: ^render.Draw_List,
	state: Warning_State,
	metadata: ^codec.Session_Metadata,
) -> (
	content_height: f32,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	render.fill_rect(list, state.bounds, state.theme.background)
	render.draw_line(
		list,
		state.bounds.x0,
		state.bounds.y0,
		state.bounds.x1,
		state.bounds.y0,
		state.theme.border,
	)

	if state.fonts == nil || state.atlas == nil {
		return 0
	}

	scale := state.scale if state.scale > 0 else 1
	left := state.bounds.x0 + 16 * scale
	width := render.rect_width(state.bounds) - 32 * scale
	step := WARNING_LINE_HEIGHT * scale
	y := state.bounds.y0 + 14 * scale - state.scroll

	warnings := codec.total_warnings(metadata)
	redactions := codec.total_redactions(metadata)

	heading := state.heading_atlas if state.heading_atlas != nil else state.atlas
	render.draw_text_clipped(
		list,
		state.fonts,
		heading,
		"Import notes",
		left,
		y,
		width,
		state.theme.heading,
	)
	y += step * 1.4

	if warnings == 0 && redactions == 0 {
		// docs/01: an empty panel explains why it is empty. "Nothing was
		// reported" is a stronger statement than a blank area, because it
		// distinguishes a clean import from a panel that failed to load.
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			"This import reported no warnings and redacted nothing.",
			left,
			y,
			width,
			state.theme.muted,
		)
		return y + step - state.bounds.y0 + state.scroll
	}

	// Serious first: a user scanning the top of the list should meet the
	// warnings that limit conclusions before the ones that only reduce
	// completeness.
	for pass in ([]Severity{.Serious, .Notice}) {
		for category in codec.Warning_Category {
			count := metadata.warnings[int(category)]
			if count == 0 || warning_severity(category) != pass {
				continue
			}
			colour := state.theme.serious if pass == .Serious else state.theme.notice
			render.draw_text_clipped(
				list,
				state.fonts,
				state.atlas,
				fmt.tprintf("%d %s", count, warning_description(category)),
				left,
				y,
				width,
				colour,
			)
			y += step
		}
	}

	if redactions > 0 {
		y += step * 0.5
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			// docs/08: reports list rule identifiers and counts, never matched
			// values. The panel shows how much was removed, never what.
			fmt.tprintf("%d values were redacted before this trace was written", redactions),
			left,
			y,
			width,
			state.theme.label,
		)
		y += step

		for category in codec.Redaction_Category {
			count := metadata.redactions[int(category)]
			if count == 0 {
				continue
			}
			render.draw_text_clipped(
				list,
				state.fonts,
				state.atlas,
				fmt.tprintf("    %d %s", count, redaction_description(category)),
				left,
				y,
				width,
				state.theme.muted,
			)
			y += step
		}
	}

	return y + step - state.bounds.y0 + state.scroll
}

// warning_summary is the one-line form for the top bar.
//
// Long enough to be actionable, short enough to sit beside the search field.
// An empty result means there is nothing to report, so the caller draws
// nothing rather than a reassuring zero.
warning_summary :: proc(metadata: ^codec.Session_Metadata) -> string {
	warnings := codec.total_warnings(metadata)
	if warnings == 0 {
		return ""
	}

	// Name the most consequential category rather than the largest count: a
	// hundred repaired timestamps matter less than one failed patch, and a
	// summary that led with the hundred would bury the one.
	for category in codec.Warning_Category {
		if metadata.warnings[int(category)] == 0 {
			continue
		}
		if warning_severity(category) != .Serious {
			continue
		}
		return fmt.tprintf(
			"%d import warnings — %d %s",
			warnings,
			metadata.warnings[int(category)],
			warning_description(category),
		)
	}

	return fmt.tprintf("%d import warnings", warnings)
}

// has_serious_warnings reports whether any warning limits what can be
// concluded, so the caller can draw attention rather than merely inform.
has_serious_warnings :: proc(metadata: ^codec.Session_Metadata) -> bool {
	for category in codec.Warning_Category {
		if metadata.warnings[int(category)] > 0 && warning_severity(category) == .Serious {
			return true
		}
	}
	return false
}
