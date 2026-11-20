-- The rate agreed on the task (tasks.settlement_*) now drives the invoice, the payment and the hotel expense.
-- Nothing re-reads exchange rates after the task is agreed.

alter table public.worker_task_invoices drop constraint if exists worker_task_invoices_fx_rate_source_check;
alter table public.worker_task_invoices
  add constraint worker_task_invoices_fx_rate_source_check
  check (fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited'));

alter table public.worker_task_payments drop constraint if exists worker_task_payments_fx_rate_source_check;
alter table public.worker_task_payments
  add constraint worker_task_payments_fx_rate_source_check
  check (fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited'));

create or replace function public.resolve_task_settlement()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  fx_row record;
  is_hotel_manager boolean;
begin
  if tg_op = 'UPDATE' then
    if exists (select 1 from public.worker_task_invoices where task_id = new.id) then
      raise exception 'Settlement terms cannot change after the task invoice is created';
    end if;
    if pg_trigger_depth() > 1 then return new; end if;
  end if;

  new.settlement_currency_code := coalesce(new.settlement_currency_code, new.currency_code);

  if new.settlement_currency_code = new.currency_code then
    new.settlement_fx_rate := 1;
    new.settlement_fx_rate_source := 'same_currency';
    new.settlement_fx_rate_fetched_at := null;
    return new;
  end if;

  if new.settlement_currency_code not in ('UGX', 'USD') then
    raise exception 'Settlement currency must be UGX or USD, or the task currency';
  end if;

  select * into fx_row
    from public.books_task_payment_fx_rate(new.currency_code::char(3), new.settlement_currency_code::char(3));

  if new.settlement_fx_rate_source in ('hotel_approved', 'hotel_edited') then
    select exists (
      select 1
        from public.user_profiles profile
        join public.books_memberships membership on membership.user_id = profile.user_id
       where profile.user_id = auth.uid()
         and profile.role = 'manager'
         and membership.organization_id = new.organization_id
    ) into is_hotel_manager;
    if not is_hotel_manager then
      raise exception 'Only the hotel manager can approve or edit the settlement rate';
    end if;
  end if;

  if new.settlement_fx_rate_source = 'hotel_edited' then
    if coalesce(new.settlement_fx_rate, 0) <= 0 then
      raise exception 'Edited settlement rate must be greater than zero';
    end if;
    new.settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
  else
    if fx_row.rate_status <> 'stored' then
      raise exception 'FX_RATE_UNAVAILABLE: No current stored % to % rate exists. Refresh the exchange rates and try again.', new.currency_code, new.settlement_currency_code;
    end if;
    new.settlement_fx_rate := fx_row.fx_rate;
    new.settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
    new.settlement_fx_rate_source := case
      when new.settlement_fx_rate_source = 'hotel_approved' then 'hotel_approved'
      else 'stored'
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists default_task_settlement on public.tasks;
drop trigger if exists resolve_task_settlement_insert on public.tasks;
drop trigger if exists resolve_task_settlement_update on public.tasks;
create trigger resolve_task_settlement_insert
  before insert on public.tasks
  for each row execute function public.resolve_task_settlement();
create trigger resolve_task_settlement_update
  before update of settlement_currency_code, settlement_fx_rate, settlement_fx_rate_source on public.tasks
  for each row execute function public.resolve_task_settlement();
drop function if exists public.default_task_settlement();

create or replace function public.create_worker_task_invoice(target_task_id uuid, manual_fx_rate numeric)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  existing_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  hotel_name text;
  hotel_base_currency char(3);
  task_currency char(3);
  worker_organization_id uuid;
  invoice_currency char(3);
  worker_vat_registered boolean;
  worker_tax_country text;
  gross_amount numeric;
  vat_rate_id uuid;
  vat_rate_percentage numeric := 0;
  subtotal_amount numeric;
  hotel_tax numeric := 0;
  customer_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
begin
  select * into task_row from public.tasks where id = target_task_id for update;
  if not found then raise exception 'Task not found'; end if;

  select * into existing_link from public.worker_task_invoices where task_id = target_task_id;
  if found then return existing_link.invoice_id; end if;

  if task_row.organization_id is null or task_row.assigned_to is null
     or coalesce(task_row.final_amount, 0) <= 0 then
    return null;
  end if;
  if task_row.settlement_fx_rate is null or task_row.settlement_fx_rate <= 0 then
    raise exception 'FX_RATE_UNAVAILABLE: The task has no agreed settlement rate';
  end if;

  select profile.user_id into worker_user_id
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.name, organization.base_currency
    into hotel_name, hotel_base_currency
    from public.books_organizations organization where organization.id = task_row.organization_id;

  task_currency := task_row.currency_code;
  invoice_currency := task_row.settlement_currency_code;

  worker_organization_id := public.ensure_worker_books_organization(worker_user_id, hotel_base_currency);
  select organization.vat_registered, organization.tax_country_code
    into worker_vat_registered, worker_tax_country
    from public.books_organizations organization where organization.id = worker_organization_id;

  gross_amount := round(task_row.final_amount * task_row.settlement_fx_rate, public.checkout_currency_minor_units(invoice_currency));
  if gross_amount <= 0 then raise exception 'Converted task amount is zero'; end if;

  if worker_vat_registered then
    select rate.id, rate.rate_percentage into vat_rate_id, vat_rate_percentage
      from public.books_tax_rates rate
     where rate.organization_id = worker_organization_id
       and rate.country_code = worker_tax_country
       and rate.tax_scope = 'invoice'
       and rate.is_active
       and rate.confirmed_at is not null
       and rate.effective_from <= current_date
       and (rate.effective_to is null or rate.effective_to >= current_date)
     order by rate.effective_from desc, rate.confirmed_at desc
     limit 1;
    if vat_rate_id is null then
      raise exception 'Confirm a VAT rate in your Books tax settings before this task can be approved';
    end if;
    subtotal_amount := round(
      gross_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(invoice_currency)
    );
    hotel_tax := task_row.final_amount - round(
      task_row.final_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(task_currency)
    );
  else
    subtotal_amount := gross_amount;
  end if;

  select contact.id into customer_id from public.books_contacts contact
   where contact.organization_id = worker_organization_id
     and lower(contact.name) = lower(hotel_name)
     and contact.type in ('customer', 'both')
   order by contact.created_at
   limit 1;
  if customer_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (worker_organization_id, hotel_name, 'customer')
    returning id into customer_id;
  end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code,
    subtotal, tax_amount, tax_rate_id, status, notes
  ) values (
    worker_organization_id, customer_id, 'TASK-' || task_row.id::text, current_date, current_date, invoice_currency,
    subtotal_amount, gross_amount - subtotal_amount, vat_rate_id, 'sent', 'Approved task: ' || task_row.title
  )
  returning * into invoice_row;

  insert into public.worker_task_invoices (
    task_id, invoice_id, worker_organization_id, hotel_organization_id,
    hotel_currency_code, hotel_amount, hotel_tax_amount,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at
  ) values (
    task_row.id, invoice_row.id, worker_organization_id, task_row.organization_id,
    task_currency, task_row.final_amount, hotel_tax,
    invoice_currency, task_row.settlement_fx_rate, task_row.settlement_fx_rate_source, task_row.settlement_fx_rate_fetched_at
  );

  select account.id into receivable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '1100';
  select account.id into revenue_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '4000';
  select account.id into vat_payable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '2100';
  if receivable_id is null or revenue_id is null or (invoice_row.tax_amount > 0 and vat_payable_id is null) then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (worker_organization_id, 'worker_task_invoice', invoice_row.id, current_date, 'Task invoice ' || invoice_row.invoice_number, worker_user_id)
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, receivable_id, invoice_row.total, 0, invoice_currency, 1),
         (journal_id, revenue_id, 0, invoice_row.subtotal, invoice_currency, 1);
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, vat_payable_id, 0, invoice_row.tax_amount, invoice_currency, 1);
  end if;

  return invoice_row.id;
end;
$$;
revoke all on function public.create_worker_task_invoice(uuid, numeric) from public, anon, authenticated;

drop function if exists public.record_worker_task_payment(uuid, text, text, numeric);
create or replace function public.record_worker_task_payment(
  p_task_id uuid,
  p_payment_method text,
  p_payment_reference text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  invoice_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  worker_name text;
  hotel_vat_registered boolean;
  reference_text text := nullif(trim(p_payment_reference), '');
  payment_id uuid;
  expense_id uuid;
  worker_contact_id uuid;
  hotel_recoverable boolean;
begin
  if auth.uid() is null then raise exception 'Sign in to record payments'; end if;
  if reference_text is null then raise exception 'A payment reference is required'; end if;

  select * into task_row from public.tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if task_row.organization_id is null
     or not public.hotel_user_manages_organization(task_row.organization_id, auth.uid()) then
    raise exception 'Only this hotel''s manager can record task payments';
  end if;
  if task_row.status <> 'completed' then raise exception 'Task must be approved before payment'; end if;
  if not exists (
    select 1 from public.task_reports report
     where report.task_id = task_row.id and report.status = 'approved'
  ) then
    raise exception 'Task report must be approved before payment';
  end if;
  if task_row.final_amount is null or task_row.final_amount <= 0 then
    raise exception 'Task has no agreed amount';
  end if;
  if task_row.assigned_to is null then raise exception 'Task has no assigned worker'; end if;
  if exists (select 1 from public.worker_task_payments where task_id = task_row.id) then
    raise exception 'Payment is already recorded for this task';
  end if;

  select profile.user_id,
         coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), 'Worker')
    into worker_user_id, worker_name
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.vat_registered into hotel_vat_registered
    from public.books_organizations organization where organization.id = task_row.organization_id;

  perform public.create_worker_task_invoice(task_row.id, null);
  select * into invoice_link from public.worker_task_invoices where task_id = task_row.id;
  select * into invoice_row from public.books_invoices where id = invoice_link.invoice_id for update;
  if invoice_row.status not in ('sent', 'overdue') then raise exception 'Task invoice is not open for payment'; end if;

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount, payment_method, payment_reference,
    recorded_by, confirmation_status
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, invoice_link.hotel_tax_amount, invoice_link.hotel_currency_code,
    invoice_link.worker_currency_code, invoice_link.fx_rate, invoice_link.fx_rate_source, invoice_link.fx_rate_fetched_at,
    invoice_row.total, invoice_row.tax_amount, p_payment_method, reference_text,
    auth.uid(), 'pending_confirmation'
  )
  returning id into payment_id;

  select contact.id into worker_contact_id
    from public.books_contacts contact
   where contact.organization_id = task_row.organization_id
     and contact.name = worker_name
     and contact.type in ('vendor', 'both')
   limit 1;
  if worker_contact_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (task_row.organization_id, worker_name, 'vendor')
    returning id into worker_contact_id;
  end if;

  hotel_recoverable := coalesce(hotel_vat_registered, false) and invoice_row.tax_amount > 0;
  if hotel_recoverable then
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values (task_row.organization_id, '1400', 'Input VAT recoverable', 'asset', true)
    on conflict (organization_id, code) do nothing;
  end if;

  insert into public.books_expenses (
    organization_id, contact_id, description, expense_date, currency_code, amount, tax_amount,
    vat_recoverable, payment_status
  ) values (
    task_row.organization_id, worker_contact_id, 'Worker payment: ' || task_row.title, current_date,
    invoice_link.worker_currency_code, invoice_row.total - invoice_row.tax_amount, invoice_row.tax_amount,
    hotel_recoverable, 'paid'
  )
  returning id into expense_id;

  update public.worker_task_payments
     set hotel_expense_id = expense_id
   where id = payment_id;

  insert into public.notifications (user_id, task_id, type, message, action_url)
  values (
    worker_user_id, task_row.id, 'task_updated',
    'The hotel recorded payment for "' || task_row.title || '". Review the payment and confirm receipt in Books.',
    '/books'
  );

  return payment_id;
end;
$$;
revoke all on function public.record_worker_task_payment(uuid, text, text) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text) to authenticated;

drop function if exists public.approve_task_report_and_award_points(uuid, numeric);
drop function if exists public.approve_task_report_and_award_points(uuid);
create or replace function public.approve_task_report_and_award_points(
  target_report_id uuid,
  p_settlement_action text default 'keep',
  p_settlement_fx_rate numeric default null
)
returns integer language plpgsql security definer volatile set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype;
  task_row public.tasks%rowtype;
  worker_user_id uuid;
  actor_role text;
  points_this_month bigint;
  reward_points integer;
  program_row public.hotel_loyalty_programs%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  if p_settlement_action not in ('keep', 'refresh', 'edit') then raise exception 'Unknown settlement action'; end if;
  select role into actor_role from public.user_profiles where user_id = auth.uid();
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id = report_row.task_id for update;
  if not found or task_row.created_by <> auth.uid() or actor_role <> 'manager' then raise exception 'Only the task manager can approve this report'; end if;
  if task_row.assigned_to is distinct from report_row.worker_id or report_row.status <> 'completed_pending_approval' then
    raise exception 'This task report is not ready for approval';
  end if;
  select user_id into worker_user_id from public.user_profiles where id = report_row.worker_id and role = 'worker';
  if worker_user_id is null then raise exception 'Assigned worker account was not found'; end if;

  if task_row.settlement_currency_code <> task_row.currency_code then
    if p_settlement_action = 'refresh' then
      update public.tasks set settlement_fx_rate_source = 'hotel_approved' where id = task_row.id;
    elsif p_settlement_action = 'edit' then
      update public.tasks
         set settlement_fx_rate = p_settlement_fx_rate, settlement_fx_rate_source = 'hotel_edited'
       where id = task_row.id;
    end if;
  end if;

  update public.task_reports set status = 'approved', last_updated_by = auth.uid(), updated_at = now() where id = report_row.id;
  update public.tasks set status = 'completed', updated_at = now() where id = task_row.id;
  perform public.create_worker_task_invoice(task_row.id, null);
  insert into public.notifications (user_id, task_id, type, message)
  values (worker_user_id, task_row.id, 'task_updated', 'Your task "' || task_row.title || '" has been approved and marked complete.');
  if task_row.organization_id is null then return 0; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id and program_enabled;
  if not found then return 0; end if;
  perform public.hotel_loyalty_make_account(task_row.organization_id, worker_user_id);
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id;
  select coalesce(sum(points_delta), 0) into points_this_month from public.hotel_loyalty_ledger_entries
  where organization_id = task_row.organization_id and user_id = worker_user_id and entry_type = 'task_earn'
    and created_at >= date_trunc('month', now());
  reward_points := least(program_row.task_approval_points, greatest(program_row.monthly_task_points_cap - points_this_month, 0)::integer);
  if reward_points > 0 and exists (select 1 from public.hotel_loyalty_accounts where organization_id = task_row.organization_id and user_id = worker_user_id and is_enrolled) then
    if public.apply_hotel_loyalty_delta(task_row.organization_id, worker_user_id, 'task_earn', reward_points,
      'approved_task', task_row.id, 'Manager-approved hotel task reward') is null then reward_points := 0; end if;
  else reward_points := 0; end if;
  perform public.qualify_hotel_loyalty_referral(task_row.organization_id, worker_user_id, 'task', 'approved_task', task_row.id, null);
  return reward_points;
end;
$$;
revoke all on function public.approve_task_report_and_award_points(uuid, text, numeric) from public, anon;
grant execute on function public.approve_task_report_and_award_points(uuid, text, numeric) to authenticated;

notify pgrst, 'reload schema';
