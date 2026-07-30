/**
 * CLDR plural selection for the catalogues. Lives in its own module rather
 * than in index.ts because the catalogues import `pr` and index.ts imports the
 * catalogues — putting it in index.ts would be a circular import.
 */

/** Whatever categories the runtime's Intl reports ('one' | 'few' | … ). Derived
 *  from the platform type so it stays correct across TypeScript lib versions. */
type Category = ReturnType<Intl.PluralRules['select']>;

/** `other` is mandatory: it is the fallback for any category a locale omits. */
export type PluralForms = Partial<Record<Category, string>> & { other: string };

let selector = new Intl.PluralRules('en');

export function setPluralLocale(locale: string): void {
  selector = new Intl.PluralRules(locale);
}

export function pr(n: number, forms: PluralForms): string {
  return forms[selector.select(n)] ?? forms.other;
}
