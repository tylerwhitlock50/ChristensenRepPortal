/**
 * The product-mix colours (components/FamilyMixBars.vue and the swatches on
 * the list beside it).
 *
 * Five hues in a FIXED order, plus a gray for "Other". They are slots, handed
 * out in order to an account's biggest families (useIntel.ts mixSlots) and
 * never cycled: a sixth family folds into "Other" rather than getting a
 * generated hue that a colour-blind reader cannot tell from one of these.
 *
 * Checked, not eyeballed. On the card's white surface, for EVERY pair (the
 * two bars can put any two side by side when a family sold in one year
 * only): worst pair ΔE 10.0 under protanopia / deuteranopia (target ≥ 8) and
 * 19.6 with full colour vision (floor 15); all five inside the lightness
 * band and over the chroma floor. Change a value and those numbers have to
 * be measured again. Blue + violet was the pair that failed first (ΔE 4.5),
 * which is why the blue is this light and the purple this deep.
 *
 * Gold, sky and pink are under 3:1 against white, which is allowed only
 * because nothing is read from colour alone here: every family's name and
 * figures are printed in the list under the bars.
 *
 * None of them is the ember (--color-accent, "late") or the danger red, and
 * the green is not the brand's CTA green: these mean "which family", never
 * a state.
 */
export const MIX_COLORS = ['#1f7a4d', '#eda100', '#5598e7', '#e87ba4', '#6a2fa0'] as const

/** "Other", and any family past the fifth. The charts' warm gray (3.7:1). */
export const MIX_OTHER_COLOR = '#8a857a'

/** A slot's colour; anything outside the five (MIX_OTHER_SLOT) is the gray. */
export function mixColor(slot: number): string {
  return MIX_COLORS[slot] ?? MIX_OTHER_COLOR
}
