-- REVIEW-ONLY, NOT DEPLOYED. Isolated additive module; existing schema is unknown.
-- Adapters deliberately fail closed until implemented against the real paper RPCs.
-- Never replace or call live paper_close from a network callback inside a DB transaction.
BEGIN;
CREATE SCHEMA IF NOT EXISTS sona_protection;
REVOKE ALL ON SCHEMA sona_protection FROM PUBLIC;
CREATE TABLE IF NOT EXISTS sona_protection.limits (
  position_id uuid PRIMARY KEY, account_id text NOT NULL,
  side text NOT NULL CHECK(side IN ('buy','sell')),
  entry numeric NOT NULL CHECK(entry>0), tp numeric, sl numeric,
  enabled boolean NOT NULL DEFAULT true, updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK(tp IS NULL OR (tp>0 AND CASE WHEN side='buy' THEN tp>entry ELSE tp<entry END)),
  CHECK(sl IS NULL OR (sl>0 AND CASE WHEN side='buy' THEN sl<entry ELSE sl>entry END))
);
CREATE TABLE IF NOT EXISTS sona_protection.executions (
  position_id uuid PRIMARY KEY, reason text NOT NULL,
  source text NOT NULL, quote_at timestamptz NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now(), fill numeric NOT NULL,
  result jsonb NOT NULL
);
ALTER TABLE sona_protection.limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE sona_protection.executions ENABLE ROW LEVEL SECURITY;
-- Required mappings: authenticate PIN without storing it, return owned open position;
-- return the current position by id for service execution; atomically close ONLY IF OPEN.
CREATE OR REPLACE FUNCTION sona_protection.owned_position(p text, tid uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'Integration required: map PIN/account authorization and position schema'; END $$;
CREATE OR REPLACE FUNCTION sona_protection.position_snapshot(tid uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'Integration required: authoritative position lookup'; END $$;
CREATE OR REPLACE FUNCTION sona_protection.close_if_open(tid uuid, price numeric, why text)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'Integration required: transactional paper balance + close-if-open'; END $$;
CREATE OR REPLACE FUNCTION public.paper_protection_set_v2(p text, tid uuid, target numeric, stop numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE pos jsonb;
BEGIN
  pos := sona_protection.owned_position(p,tid);
  IF pos->>'status' IS DISTINCT FROM 'open' OR pos->>'account_id' IS NULL THEN
    RAISE EXCEPTION 'Owned open paper position required';
  END IF;
  INSERT INTO sona_protection.limits(position_id,account_id,side,entry,tp,sl)
  VALUES(tid,pos->>'account_id',pos->>'direction',(pos->>'entry')::numeric,target,stop)
  ON CONFLICT(position_id) DO UPDATE SET tp=EXCLUDED.tp,sl=EXCLUDED.sl,enabled=true,updated_at=now();
  RETURN jsonb_build_object('stored',true,'schema',2);
END $$;
-- Service-role only. Scheduler must supply actual source ts and executable sides.
CREATE OR REPLACE FUNCTION public.sona_protection_tick_v2(bid numeric, ask numeric, quote_at timestamptz, source text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE lim record; pos jsonb; mark numeric; reason text; result jsonb; count_closed integer := 0;
BEGIN
  IF source <> 'swissquote' OR bid IS NULL OR ask IS NULL OR bid<=0 OR ask<bid
     OR bid::text IN ('NaN','Infinity','-Infinity') OR ask::text IN ('NaN','Infinity','-Infinity')
     OR quote_at IS NULL OR quote_at<clock_timestamp()-interval '60 seconds'
     OR quote_at>clock_timestamp()+interval '5 seconds' THEN
    RAISE EXCEPTION 'Fresh verified executable quote required';
  END IF;
  FOR lim IN SELECT * FROM sona_protection.limits WHERE enabled FOR UPDATE SKIP LOCKED LOOP
    IF EXISTS(SELECT 1 FROM sona_protection.executions e WHERE e.position_id=lim.position_id) THEN CONTINUE; END IF;
    pos := sona_protection.position_snapshot(lim.position_id);
    IF pos->>'status' IS DISTINCT FROM 'open' THEN
      UPDATE sona_protection.limits SET enabled=false WHERE position_id=lim.position_id;
      CONTINUE;
    END IF;
    mark := CASE WHEN lim.side='buy' THEN bid ELSE ask END;
    reason := CASE
      WHEN lim.sl IS NOT NULL AND CASE WHEN lim.side='buy' THEN mark<=lim.sl ELSE mark>=lim.sl END THEN 'SL hit'
      WHEN lim.tp IS NOT NULL AND CASE WHEN lim.side='buy' THEN mark>=lim.tp ELSE mark<=lim.tp END THEN 'TP hit'
      ELSE NULL END;
    IF reason IS NULL THEN CONTINUE; END IF;
    -- This adapter MUST update balance and position together in this transaction.
    -- A unique position_id plus locked limits deduplicates scheduler invocations;
    -- close_if_open is still mandatory for races with manual/legacy clients.
    result := sona_protection.close_if_open(lim.position_id,mark,reason);
    IF result->>'status' IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'Close not verified'; END IF;
    INSERT INTO sona_protection.executions(position_id,reason,source,quote_at,fill,result)
    VALUES(lim.position_id,reason,source,quote_at,mark,result);
    UPDATE sona_protection.limits SET enabled=false WHERE position_id=lim.position_id;
    count_closed := count_closed+1;
  END LOOP;
  RETURN count_closed;
END $$;
-- Fail-closed capability: do not enable until adapters, real scheduler heartbeat,
-- read-back limits/executions RPCs, opening integration and cross-device tests exist.
CREATE OR REPLACE FUNCTION public.paper_protection_capabilities_v2(p text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('schema',2,'scheduled',false,'atomic_close',false)
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA sona_protection FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_protection_set_v2(text,uuid,numeric,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sona_protection_tick_v2(numeric,numeric,timestamptz,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.paper_protection_capabilities_v2(text) FROM PUBLIC;
-- Deliberately NO scheduler, grants, live data migration, or capability enablement.
-- Reviewed deployment grants tick to service_role only. PIN-protected RPC grants
-- must match existing project's verified auth contract, not a guessed auth model.
COMMIT;
