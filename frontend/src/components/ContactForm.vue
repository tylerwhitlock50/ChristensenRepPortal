<script setup lang="ts">
import { computed, ref, useId } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import { z } from 'zod'
import AppButton from '@/components/ui/AppButton.vue'
import {
  useAddContact,
  useUpdateContact,
  type Contact,
} from '@/composables/useContacts'

const props = defineProps<{
  customerKey: string
  /** Present = edit mode. Absent = add mode. */
  contact?: Contact | null
}>()

const emit = defineEmits<{
  saved: [contact: Contact]
  cancel: []
}>()

const isEdit = computed(() => !!props.contact)
const uid = useId()

/* ---- validation ---------------------------------------------------------
   Every field is a plain string (never undefined) so the inputs stay
   controlled and zod never has to model "missing". Optional fields validate
   only when the rep actually typed something — an empty box is not an error.
   No z.union() on purpose: @vee-validate/zod still reads the zod 3 shape of a
   union issue, so a union error would blow up instead of rendering.
------------------------------------------------------------------------- */
const emailRule = z.email()

function looksLikeEmail(value: string): boolean {
  return value === '' || emailRule.safeParse(value).success
}

function looksLikePhone(value: string): boolean {
  if (value === '') return true
  // Permissive on purpose: reps paste "(801) 555-0134 x12" and extensions,
  // country codes and dashes are all legitimate. We only insist there are
  // enough digits to be dialable.
  if (!/^[0-9+()\-.\s]*(?:(?:ext|x)\.?\s*\d{1,6})?$/i.test(value)) return false
  return (value.match(/\d/g) ?? []).length >= 7
}

const schema = toTypedSchema(
  z.object({
    name: z
      .string()
      .trim()
      .min(1, 'A name is required')
      .max(120, 'That name is too long'),
    title: z.string().trim().max(120, 'That title is too long'),
    phone: z
      .string()
      .trim()
      .max(40, 'That phone number is too long')
      .refine(looksLikePhone, "That doesn't look like a phone number"),
    email: z
      .string()
      .trim()
      .max(200, 'That email address is too long')
      .refine(looksLikeEmail, "That email address doesn't look right"),
    is_primary: z.boolean(),
    notes: z.string().trim().max(2000, 'Keep notes under 2,000 characters'),
  }),
)

const { defineField, errors, handleSubmit, isSubmitting } = useForm({
  validationSchema: schema,
  initialValues: {
    name: props.contact?.name ?? '',
    title: props.contact?.title ?? '',
    phone: props.contact?.phone ?? '',
    email: props.contact?.email ?? '',
    is_primary: props.contact?.is_primary ?? false,
    notes: props.contact?.notes ?? '',
  },
})

const [name, nameAttrs] = defineField('name')
const [title, titleAttrs] = defineField('title')
const [phone, phoneAttrs] = defineField('phone')
const [email, emailAttrs] = defineField('email')
const [isPrimary] = defineField('is_primary')
const [notes, notesAttrs] = defineField('notes')

/* ---- save ---------------------------------------------------------------- */
const add = useAddContact()
const update = useUpdateContact()
const serverError = ref('')

/** Only offer to dial once there's actually a number worth dialing. */
const callHref = computed(() => {
  const value = (phone.value ?? '').trim()
  if (!value || !looksLikePhone(value)) return ''
  return `tel:${value.replace(/[^\d+;,*#]/g, '')}`
})

const onSubmit = handleSubmit(async (values) => {
  serverError.value = ''
  try {
    const saved = props.contact
      ? await update.mutateAsync({
          id: props.contact.id,
          customerKey: props.customerKey,
          values,
        })
      : await add.mutateAsync({ customerKey: props.customerKey, values })
    emit('saved', saved)
  } catch (e) {
    serverError.value = (e as Error).message || 'Could not save that contact.'
  }
})

const inputClass =
  'tap-target w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-base outline-none focus:border-zinc-900'
</script>

<template>
  <form
    class="rounded-lg border border-zinc-200 bg-zinc-50 p-4"
    novalidate
    @submit="onSubmit"
  >
    <h3 class="mb-3 text-sm font-semibold text-zinc-900">
      {{ isEdit ? 'Edit contact' : 'New contact' }}
    </h3>

    <div class="space-y-3">
      <!-- Name -->
      <div>
        <label :for="`${uid}-name`" class="mb-1 block text-sm font-medium text-zinc-700">
          Name
        </label>
        <input
          :id="`${uid}-name`"
          v-model="name"
          v-bind="nameAttrs"
          type="text"
          autocomplete="name"
          autocapitalize="words"
          enterkeyhint="next"
          placeholder="Buyer's name"
          :class="inputClass"
          :aria-invalid="!!errors.name || undefined"
          :aria-describedby="errors.name ? `${uid}-name-err` : undefined"
        />
        <p v-if="errors.name" :id="`${uid}-name-err`" class="mt-1 text-sm text-red-700">
          {{ errors.name }}
        </p>
      </div>

      <!-- Title -->
      <div>
        <label :for="`${uid}-title`" class="mb-1 block text-sm font-medium text-zinc-700">
          Title <span class="font-normal text-zinc-500">(optional)</span>
        </label>
        <input
          :id="`${uid}-title`"
          v-model="title"
          v-bind="titleAttrs"
          type="text"
          autocomplete="organization-title"
          enterkeyhint="next"
          placeholder="Store manager, buyer…"
          :class="inputClass"
          :aria-invalid="!!errors.title || undefined"
          :aria-describedby="errors.title ? `${uid}-title-err` : undefined"
        />
        <p v-if="errors.title" :id="`${uid}-title-err`" class="mt-1 text-sm text-red-700">
          {{ errors.title }}
        </p>
      </div>

      <!-- Phone -->
      <div>
        <label :for="`${uid}-phone`" class="mb-1 block text-sm font-medium text-zinc-700">
          Phone <span class="font-normal text-zinc-500">(optional)</span>
        </label>
        <div class="flex gap-2">
          <input
            :id="`${uid}-phone`"
            v-model="phone"
            v-bind="phoneAttrs"
            type="tel"
            inputmode="tel"
            autocomplete="tel"
            enterkeyhint="next"
            placeholder="(801) 555-0134"
            :class="[inputClass, 'flex-1 min-w-0']"
            :aria-invalid="!!errors.phone || undefined"
            :aria-describedby="errors.phone ? `${uid}-phone-err` : undefined"
          />
          <a
            v-if="callHref"
            :href="callHref"
            class="tap-target inline-flex shrink-0 items-center rounded-lg border border-zinc-300 bg-white px-3 text-sm font-medium text-zinc-900"
          >
            Call
          </a>
        </div>
        <p v-if="errors.phone" :id="`${uid}-phone-err`" class="mt-1 text-sm text-red-700">
          {{ errors.phone }}
        </p>
      </div>

      <!-- Email -->
      <div>
        <label :for="`${uid}-email`" class="mb-1 block text-sm font-medium text-zinc-700">
          Email <span class="font-normal text-zinc-500">(optional)</span>
        </label>
        <input
          :id="`${uid}-email`"
          v-model="email"
          v-bind="emailAttrs"
          type="email"
          inputmode="email"
          autocomplete="email"
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          enterkeyhint="next"
          placeholder="buyer@store.com"
          :class="inputClass"
          :aria-invalid="!!errors.email || undefined"
          :aria-describedby="errors.email ? `${uid}-email-err` : undefined"
        />
        <p v-if="errors.email" :id="`${uid}-email-err`" class="mt-1 text-sm text-red-700">
          {{ errors.email }}
        </p>
      </div>

      <!-- Primary -->
      <label
        :for="`${uid}-primary`"
        class="tap-target flex items-center gap-3 rounded-lg border border-zinc-300 bg-white px-3"
      >
        <input
          :id="`${uid}-primary`"
          v-model="isPrimary"
          type="checkbox"
          class="size-5 shrink-0 rounded border-zinc-400"
        />
        <span class="text-sm font-medium text-zinc-700">
          Main person to ask for
        </span>
      </label>

      <!-- Notes -->
      <div>
        <label :for="`${uid}-notes`" class="mb-1 block text-sm font-medium text-zinc-700">
          Notes <span class="font-normal text-zinc-500">(optional)</span>
        </label>
        <textarea
          :id="`${uid}-notes`"
          v-model="notes"
          v-bind="notesAttrs"
          rows="3"
          placeholder="Best time to call, who they report to…"
          class="w-full rounded-lg border border-zinc-300 bg-white p-3 text-base outline-none focus:border-zinc-900"
          :aria-invalid="!!errors.notes || undefined"
          :aria-describedby="errors.notes ? `${uid}-notes-err` : undefined"
        />
        <p v-if="errors.notes" :id="`${uid}-notes-err`" class="mt-1 text-sm text-red-700">
          {{ errors.notes }}
        </p>
      </div>
    </div>

    <p v-if="serverError" role="alert" class="mt-3 text-sm text-red-700">
      {{ serverError }}
    </p>

    <div class="mt-4 flex gap-2">
      <AppButton type="submit" :loading="isSubmitting">
        {{ isEdit ? 'Save changes' : 'Add contact' }}
      </AppButton>
      <AppButton variant="ghost" @click="emit('cancel')">Cancel</AppButton>
    </div>
  </form>
</template>
