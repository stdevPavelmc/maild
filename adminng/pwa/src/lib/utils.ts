import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

/** shadcn/ui's class combiner (kept local so the skeleton has no UI package). */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
