CREATE OR REPLACE PACKAGE BODY APPS.Cmg_Load_Ret_Pck AS

/*****************************************************************************
-- +=========================================================================+
-- |              Comag Marketing Group, LLC                                 |
-- +=========================================================================+
-- |                                                                         |
-- |                                                                         |
-- |  Package Spec                                                           |
-- |                                                                         |
-- |  FILENAME:       CMG_LOAD_RET_PCK                                       |
-- |                                                                         |
-- |  DESCRIPTION:    Load Return Process                                    |
-- |                                                                         |
-- |                                                                         |
-- |Change Record:                                                           |
-- |===============                                                          |
-- |Version   Date        Author           Remarks                           |
-- |=======  ===========  ==============   ==================================|
-- |  1.11   14-Nov-2007  Azhar Hussain    Modification made as per SCR 4295 |
-- |                                   Cover Price and Selling Price Changes |
-- |                                                                         |
-- |  1.12   20-Oct-2010   Uday T           SCR 6658                         |
--    1.13   20-Oct-2014   Uday T           SCR  8385                        |
-- |  1.14   09-June-2016 Uday T           SCR 8637                          |
-- +=========================================================================+
*****************************************************************************/
/******************************************************************************
   NAME:       CMG_LOAD_RET_PCK
   PURPOSE:

   REVISIONS:
   Ver        Date        Author           Description
   ---------  ----------  ---------------  ------------------------------------
   1.0        5/9/2005    Jim Stuart       Created this package body.
   1.1        7/7/05      J.Stuart         Changed ordered_date to equal sysdate.
   1.2        7/8/05      J.Stuart         Changed values for orig_sys_document_ref, line.attrobute14,
                                           to_char date format for line dff. Added column
                                           customer_po_number for header.
   1.3        7/13/05     J.Stuart         Changes for default salesrep_id,sales_channel_code.
                                           Changed cursor c_cur to only select line quantities gretater than 0.
   1.4        7/17/05     J.Stuart         If return reason code is bad product, check item id,
                                           if null, assign invalid item id.
   1.5        7/18/05     J.Stuart         Added attribute6 to c_item_info cursor. If bipad from
                                           adjustment table is null use item bipad.
   1.6        7/20/05     J.Stuart         Fixed grouping of orders, unit_selling_price, bipad for
                                           certain reason codes.
   1.7        7/28/05     J.Stuart         Made sure certain columns are getting populated.

******************************************************************************/

-- cursor definitions
-- this is the main cursor for this package
CURSOR c_cur
IS
SELECT /*+ FIRST_ROWS */
       hdr.adjustment_header_id,
       hdr.created_by,
       hdr.creation_date,
       hdr.last_updated_by,
       hdr.last_update_date,
       hdr.customer_ref_nr,
       hdr.tally_nr,
       hdr.adjustment_flag,
       hdr.record_interfaced,
       hdr.account_nr,
       hdr.source,
       hdr.total_copies,
       hdr.customer_id,
       hdr.customer_name,
       hdr.bill_to_site_use_id,
       hdr.ship_to_site_use_id,
       hdr.return_date,
       hdr.processed_date,
       hdr.employee_assigned_to,
       hdr.order_category,
       hdr.order_type_id,
       hdr.valid_status_flag,
       hdr.duplicate_flag,
       hdr.store_nr,
       hdr.price_list_id,
       hdr.salesrep_id,
       hdr.sales_channel_code,
       hdr.original_order_header_id,
       hdr.soh_original_system_ref,
       hrl.original_order_header_id line_orig_header_id,
       hrl.original_order_line_id,
       hrl.extended_price,
       hrl.unit_price,
       hrl.inventory_item_id,
       hrl.warehouse_id,
       hrl.line_nr,
       hrl.add_on_code,
       hrl.adjustment_line_id,
       hrl.item_nr,
       hrl.quantity,
       hrl.adjustment_flag line_adjustment_flag,
       hrl.corrected_flag,
       hrl.user_rejected_flag,
       hrl.override_flag,
       hrl.line_interfaced,
       hrl.bar_code,
       hrl.bipad,
       hrl.isbn,
       hrl.magazine,
       hrl.issue_code,
       hrl.cover_date_txt,
       hrl.en_title,
       hrl.upc,
       hrl.cover_price,
       hrl.valid_status_flag line_valid_status_flag,
       hrl.invalid_reason_code,
       NVL(hrl.netsale_revalidation_level,'BILL_TO') netsale_revalidation_level,
       hrl.sol_original_system_line_ref
  FROM apps.hdg_ret_adj_lines_tbl@prodapps.world hrl,
       apps.hdg_ret_adj_header_tbl@prodapps.world hdr
 WHERE hrl.quantity != 0
   AND hrl.adjustment_header_id     = hdr.adjustment_header_id
   AND hrl.line_interfaced          = 'N'
   AND hdr.record_interfaced        = 'N'
   AND hdr.valid_status_flag        = 'Y'
   AND hdr.order_category           = 'RMA'
   AND hrl.adjustment_header_id=1554570 and issue_code='201551'
   ORDER BY hdr.adjustment_header_id;

-- gets the original sales order header
CURSOR c_orig_sales_header( p_header_id IN  oe_order_headers.header_id%TYPE )
IS
  SELECT *
  FROM oe_order_headers
  WHERE header_id = p_header_id;

-- gets the original sales order line
-- if a return then it walks up the tree to the original
CURSOR c_orig_sales_line( p_line_id    IN  oe_order_lines.line_id%TYPE )
IS
  SELECT *
  FROM   oe_order_lines
  START WITH line_id                 = p_line_id
  CONNECT BY PRIOR reference_line_id = line_id
  ORDER BY LEVEL DESC;

-- sales order line pricing attribute
CURSOR c_line_attribs( p_header_id  IN  oe_order_headers.header_id%TYPE,
                       p_line_id    IN  oe_order_lines.line_id%TYPE )
IS
  SELECT pricing_context,
         pricing_attribute1
  FROM   oe_order_price_attribs
  WHERE  line_id   = p_line_id
  AND    header_id = p_header_id;

-- gets the order source id
CURSOR c_ord_source( p_source_name   IN  oe_order_sources.name%TYPE )
IS
SELECT order_source_id
FROM   oe_order_sources
WHERE  name = p_source_name;

-- gets the order type information
-- this will be based on the return or the customer attributes
CURSOR c_trans_type( p_type_id  IN oe_transaction_types.transaction_type_id%TYPE )
IS
  SELECT order_category_code,
         currency_code,
         transaction_type_id,
         conversion_type_code,
         accounting_rule_id,
         invoicing_rule_id
  FROM   oe_transaction_types
  WHERE  transaction_type_id = p_type_id
  AND    TRUNC(SYSDATE) BETWEEN start_date_active AND NVL(end_date_active,TRUNC(SYSDATE+1));

-- get the customer attributes
CURSOR c_cust_attribs( p_cust_id  IN ra_customers.customer_id%TYPE )
IS
  SELECT cca.price_list_id,
         cca.order_type_id,
         cca.primary_salesrep_id,
         cca.tax_code,
         qlh.currency_code
  FROM   qp_list_headers qlh,
         cmg_customer_attributes_vw cca
  WHERE  qlh.list_header_id = cca.price_list_id
  AND    cca.customer_id    = p_cust_id;

-- get the editions information for an item
CURSOR c_edition( p_item_id     IN  mtl_system_items.inventory_item_id%TYPE,
                  p_issue_code  IN  mtl_item_revisions.attribute7%TYPE )
IS
  SELECT attribute7       issue_code,
         attribute8       cover_date,
         attribute10      upc_code,
         attribute13      edition,
         TO_CHAR(effectivity_date,'DD-MON-YYYY') on_sale_date,
         attribute11      off_sale_date,
         attribute12      last_return_date
  FROM   mtl_item_revisions
  WHERE  organization_id   = Cmg_Utility_Pck.org_id('HDG')
  AND    attribute7 = p_issue_code
  AND    inventory_item_id = p_item_id
  and    nvl(attribute1,'N') ='N'
  AND    ROWNUM            = 1;

-- get the item informatoin
CURSOR c_item_info( p_item_id  IN  oe_order_lines.inventory_item_id%TYPE )
IS
  SELECT primary_uom_code,
         attribute6   bipad_code
  FROM   mtl_system_items
  WHERE  organization_id   = Cmg_Utility_Pck.org_id('HDG')
  AND    inventory_item_id = p_item_id;

-- get the default sales rep id
CURSOR salesrep_id_cur
IS
  SELECT salesrep_id
  FROM   ra_salesreps
  WHERE  UPPER(name) = 'NO SALES CREDIT';

-- get the default sales credit id
CURSOR sales_credit_type_cur
IS
  SELECT sales_credit_type_id
  FROM   oe_sales_credit_types
  WHERE  UPPER(name) = 'QUOTA SALES CREDIT';

-- get the default for bad product item
CURSOR invalid_item_cur
IS
  SELECT inventory_item_id bad_inv_item_id,
         organization_id,
         primary_uom_code
  FROM   mtl_system_items
  WHERE  description     LIKE 'INVALID PRODUCT%'
  AND    organization_id = Cmg_Utility_Pck.org_id('HDG');

-- get the error messages from the order import run
CURSOR c_intf_status( p_source_id  IN  oe_order_sources.order_source_id%TYPE,
                      p_request_id IN  fnd_concurrent_requests.request_id%TYPE )
IS
  SELECT h.orig_sys_document_ref,
         m.entity_code,
         m.message_text
  FROM   oe_processing_msgs_vl m,
         oe_headers_interface h
  WHERE  m.request_id                = h.request_id
  AND    m.order_source_id           = h.order_source_id
  AND    m.original_sys_document_ref = h.orig_sys_document_ref
  AND    ( m.TYPE                    = 'ERROR'
           OR m.TYPE IS NULL )
  AND    m.message_status_code       = 'OPEN'
  AND    h.ready_flag                = 'Y'
  AND    h.error_flag                = 'Y'
  AND    h.order_source_id           = p_source_id
  AND    h.request_id IN ( SELECT fcr.request_id
                           FROM   fnd_concurrent_requests fcr
                           START WITH fcr.parent_request_id = p_request_id
                           CONNECT BY PRIOR fcr.request_id  = fcr.parent_request_id);

-- count to see if any errors occured during the order import process
CURSOR c_err_count( p_request_id  IN  fnd_concurrent_requests.request_id%TYPE )
IS
  SELECT COUNT(*)
  FROM   oe_headers_interface ohi
  WHERE  ohi.request_id IN ( SELECT fcr.request_id
                             FROM   fnd_concurrent_requests fcr
                             START WITH fcr.parent_request_id = p_request_id
                             CONNECT BY PRIOR fcr.request_id  = fcr.parent_request_id)
  AND ohi.error_flag      = 'Y';

-- get the number of order import instances to submit
CURSOR c_num_threads
IS
  SELECT TO_NUMBER(meaning) num_threads
  FROM   hdg_lookup_tbl
  WHERE  lookup_type = 'RMA_IMPORT'
  AND    lookup_code = 'MAXIMUM THREADS';

--  Table definitions
TYPE ord_tbl IS TABLE OF c_cur%ROWTYPE
  INDEX BY BINARY_INTEGER;

TYPE source_rec IS RECORD(
  source_name    oe_order_sources.name%TYPE );

TYPE source_tbl IS TABLE OF source_rec
  INDEX BY BINARY_INTEGER;

ord_rec       ord_tbl;
src_rec       source_tbl;

-- variables
intf_head_rec                   oe_headers_interface%ROWTYPE;
intf_line_rec                   oe_lines_interface%ROWTYPE;
orig_head_rec                   c_orig_sales_header%ROWTYPE;
orig_line_rec                   c_orig_sales_line%ROWTYPE;
line_attribs_rec                c_line_attribs%ROWTYPE;
ord_type_rec                    c_trans_type%ROWTYPE;
cust_attr_rec                   c_cust_attribs%ROWTYPE;
invalid_item_rec                invalid_item_cur%ROWTYPE;
item_rec                        c_item_info%ROWTYPE;
edition_rec                     c_edition%ROWTYPE;
v_credit_type_id                oe_sales_credit_types.sales_credit_type_id%TYPE;
v_salesrep_id                   ra_salesreps.salesrep_id%TYPE;
v_hold                          hdg_ret_adj_header_tbl.adjustment_header_id%TYPE := NULL;
v_retcode                       NUMBER;
v_errbuf                        VARCHAR2(100);
v_dphase                        VARCHAR2(20) ;
v_dstatus                       VARCHAR2(20) ;
v_filename                      VARCHAR2(100);
v_price_context                 VARCHAR2(15)  := 'Upgrade Context';
v_hdr_cnt                       NUMBER        := 0;
v_returnable_qty                NUMBER;
v_err_count                     NUMBER;
v_sysdate                       DATE          := SYSDATE;
load_flag                       BOOLEAN;
i                               INTEGER;
v_request_id                    fnd_concurrent_requests.request_id%TYPE := Fnd_Global.CONC_REQUEST_ID;

FUNCTION get_ord_source( p_source_name  IN  oe_order_sources.name%TYPE )
RETURN oe_order_sources.order_source_id%TYPE
IS

v_hold   oe_order_sources.order_source_id%TYPE;

BEGIN

OPEN  c_ord_source( p_source_name );
FETCH c_ord_source INTO v_hold;
CLOSE c_ord_source;

RETURN NVL(v_hold,-1);

END get_ord_source;

FUNCTION get_thread_count
RETURN NUMBER
IS

v_hold  NUMBER;

BEGIN

OPEN  c_num_threads;
FETCH c_num_threads INTO v_hold;
CLOSE c_num_threads;

RETURN v_hold;

EXCEPTION
  WHEN OTHERS THEN
    RETURN 1;
END get_thread_count;

FUNCTION err_count( p_request_id  IN  fnd_concurrent_requests.request_id%TYPE )
RETURN NUMBER
IS

v_hold   NUMBER;

BEGIN

OPEN  c_err_count( p_request_id );
FETCH c_err_count INTO v_hold;
CLOSE c_err_count;

RETURN NVL(v_hold,0);

END err_count;

FUNCTION get_list_price( p_head  IN  oe_headers_interface%ROWTYPE,
                         p_line  IN  oe_lines_interface%ROWTYPE )
RETURN NUMBER
IS

v_hold                  NUMBER;
v_return_status         VARCHAR2(1);
v_msg_count             NUMBER;

BEGIN

Hdgoea67_Pck.hdgoea67_list_price_prc(
  p_price_list_id     => p_head.price_list_id,
  p_inventory_item_id => p_line.inventory_item_id,
  p_unit_code         => p_line.order_quantity_uom,
  p_pricing_attribute => p_line.pricing_attribute1,
  p_list_price        => v_hold,
  p_return_status     => v_return_status,
  p_msg_data          => v_msg_count );

RETURN NVL(v_hold,0);

END get_list_price;

PROCEDURE intialization
IS
BEGIN

OPEN  salesrep_id_cur;
FETCH salesrep_id_cur INTO v_salesrep_id;
CLOSE salesrep_id_cur;

OPEN  sales_credit_type_cur;
FETCH sales_credit_type_cur INTO v_credit_type_id;
CLOSE sales_credit_type_cur;

OPEN  invalid_item_cur;
FETCH invalid_item_cur INTO invalid_item_rec;
CLOSE invalid_item_cur;

EXCEPTION
  WHEN OTHERS THEN
    Cmg_Utility_Pck.write_output(' Intialization procedure failed => '||SQLERRM);
    RAISE;
END intialization;

PROCEDURE MISMATCH_ORDERTYPE_PRC IS

CURSOR RET_CUR IS
select h.adjustment_header_id,get_isspc_fnc(bipad,issue_code) ISS_PCT_ID,M.WHOLESALER_PROFITCENTER_ID,M.derived_ordertype
from hdg_ret_adj_header_tbl h,
     hdg.hdg_ret_adj_lines_tbl l,
     hdg.gen_profitcenter_mapping_tbl m,
     ra_customers c,
     apps.oe_transaction_types t
where h.customer_id=c.customer_id
and  h.adjustment_header_id=l.adjustment_header_id
and  l.line_interfaced          = 'N'
and  h.record_interfaced        = 'N'
and  h.valid_status_flag        = 'Y'
and  h.order_category           = 'RMA'
and  h.order_type_id            = t.transaction_type_id
and  substr(c.customer_name,1,1)=m.wholesaler_pc_name
and  substr(t.name,1,1)=m.derived_ordertype
and  l.invalid_reason_code is null  /* it will only look for the lines which are valid and have mixed profitcenter*/
--and h.adjustment_header_id in (1533869,1533870,1533863,1533863,1533864,1533865,1533866,1533867,1533868)
group by get_isspc_fnc(bipad,issue_code),h.adjustment_header_id,M.WHOLESALER_PROFITCENTER_ID,M.derived_ordertype
order by h.adjustment_header_id;


CURSOR GEN_PROFIT_CUR(P_ISS_PCT_ID IN VARCHAR2,P_WH_PCT_ID IN NUMBER,P_ORDER_TYPE IN VARCHAR2) IS
SELECT NVL(COUNT(*),0)
FROM HDG.GEN_PROFITCENTER_MAPPING_TBL
WHERE TO_CHAR(ISSUE_PROFITCENTER_ID)=P_ISS_PCT_ID
AND  WHOLESALER_PROFITCENTER_ID=P_WH_PCT_ID
AND  DERIVED_ORDERTYPE=P_ORDER_TYPE;


V_COUNT NUMBER;


BEGIN

FOR RET_REC IN RET_CUR LOOP
    OPEN GEN_PROFIT_CUR ( RET_REC.ISS_PCT_ID,RET_REC.WHOLESALER_PROFITCENTER_ID,RET_REC.derived_ordertype);
    FETCH GEN_PROFIT_CUR INTO V_COUNT;
      IF V_COUNT =0 AND  RET_REC.ISS_PCT_ID !='NO ISSUE PROFITCENTER' THEN
       -- DBMS_OUTPUT.PUT_LINE('Not a valid  adj id:'||ret_rec.adjustment_header_id||'   '||
         --                                               ret_rec.ISS_PCT_ID||'   '||
           --                                             ret_rec.WHOLESALER_PROFITCENTER_ID||'   '||
             --                                           ret_rec.derived_ordertype);
        UPDATE HDG.HDG_RET_ADJ_HEADER_TBL
        SET VALID_STATUS_FLAG='N'
        WHERE ADJUSTMENT_HEADER_ID=RET_REC.ADJUSTMENT_HEADER_ID;
       
        UPDATE HDG.HDG_RET_ADJ_LINES_TBL
        SET VALID_STATUS_FLAG='N'
        WHERE ADJUSTMENT_HEADER_ID=RET_REC.ADJUSTMENT_HEADER_ID;
         
      END IF;
     
     CLOSE GEN_PROFIT_CUR;
   
END LOOP;

COMMIT;

END MISMATCH_ORDERTYPE_PRC;

PROCEDURE load_source( p_name   IN  oe_order_sources.name%TYPE )
IS

v_exists       VARCHAR2(1);

BEGIN

Cmg_Utility_Pck.log_msg(' Inside load_source',p_name);
Cmg_Utility_Pck.log_msg('  Count',src_rec.COUNT);

v_exists := 'N';

IF src_rec.COUNT > 0 THEN
--   Cmg_Utility_Pck.write_output('in load_source procedure if count>0 ');
  FOR x IN src_rec.FIRST..src_rec.LAST LOOP

    IF src_rec(x).source_name = p_name THEN

      v_exists := 'Y';

    END IF;

    Cmg_Utility_Pck.write_output('v_exists '||v_exists);

  END LOOP;
END IF;

IF v_exists = 'N' THEN

  src_rec(src_rec.COUNT + 1).source_name := p_name;

END IF;

END load_source;

PROCEDURE get_edition( p_item_id     IN  mtl_system_items.inventory_item_id%TYPE,
                       p_issue_code  IN  mtl_item_revisions.attribute7%TYPE )
IS
BEGIN

OPEN  c_edition( p_item_id, p_issue_code );
FETCH c_edition INTO edition_rec;

IF ( c_edition%NOTFOUND OR c_edition%NOTFOUND IS NULL ) THEN
  edition_rec := NULL;
END IF;

CLOSE c_edition;

END get_edition;

PROCEDURE get_ord_type( p_type_id  IN oe_transaction_types.transaction_type_id%TYPE )
IS
BEGIN

OPEN  c_trans_type( p_type_id );
FETCH c_trans_type INTO ord_type_rec;

IF ( c_trans_type%NOTFOUND OR c_trans_type%NOTFOUND IS NULL ) THEN
  ord_type_rec := NULL;
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_trans_type;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_trans_type%isopen THEN
      CLOSE c_trans_type;
    END IF;
    Cmg_Utility_Pck.write_output(' Error with order type => '||p_type_id);
  WHEN OTHERS THEN
    IF c_trans_type%isopen THEN
      CLOSE c_trans_type;
    END IF;
    Cmg_Utility_Pck.write_output(' Error with order type => '||p_type_id);
END get_ord_type;

PROCEDURE get_cust_atts( p_cust_id  IN  ra_customers.customer_id%TYPE )
IS
BEGIN

OPEN  c_cust_attribs( p_cust_id );
FETCH c_cust_attribs INTO cust_attr_rec;

IF ( c_cust_attribs%NOTFOUND OR c_cust_attribs%NOTFOUND IS NULL ) THEN
  cust_attr_rec := NULL;
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_cust_attribs;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_cust_attribs%isopen THEN
      CLOSE c_cust_attribs;
    END IF;
    Cmg_Utility_Pck.write_output(' Error get_cust_atts => '||p_cust_id);
  WHEN OTHERS THEN
    IF c_cust_attribs%isopen THEN
      CLOSE c_cust_attribs;
    END IF;
    Cmg_Utility_Pck.write_output(' Error get_cust_atts => '||p_cust_id);
END get_cust_atts;

PROCEDURE get_item_info( p_item_id  IN  oe_order_lines.inventory_item_id%TYPE )
IS
BEGIN

OPEN  c_item_info( p_item_id );
FETCH c_item_info INTO item_rec;

IF ( c_item_info%NOTFOUND OR c_item_info%NOTFOUND IS NULL ) THEN
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_item_info;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_item_info%isopen THEN
      CLOSE c_item_info;
    END IF;
    Cmg_Utility_Pck.write_output(' Item info error => '||p_item_id||'-'||SQLERRM);
  WHEN OTHERS THEN
    IF c_item_info%isopen THEN
      CLOSE c_item_info;
    END IF;
    Cmg_Utility_Pck.write_output(' Item info error => '||p_item_id||'-'||SQLERRM);
 END get_item_info;

PROCEDURE get_orig_header( p_header_id  IN  oe_order_headers.header_id%TYPE )
IS
BEGIN

OPEN  c_orig_sales_header( p_header_id );
FETCH c_orig_sales_header INTO orig_head_rec;

IF ( c_orig_sales_header%NOTFOUND OR c_orig_sales_header%NOTFOUND IS NULL ) THEN
  orig_head_rec := NULL;
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_orig_sales_header;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_orig_sales_header%isopen THEN
      CLOSE c_orig_sales_header;
    END IF;
    Cmg_Utility_Pck.write_output(' Sales order header error => '||p_header_id||'-'||SQLERRM);
  WHEN OTHERS THEN
    IF c_orig_sales_header%isopen THEN
      CLOSE c_orig_sales_header;
    END IF;
    Cmg_Utility_Pck.write_output(' Sales order header error => '||p_header_id||'-'||SQLERRM);
END get_orig_header;

PROCEDURE get_orig_line( p_line_id    IN  oe_order_lines.line_id%TYPE )
IS
BEGIN

OPEN  c_orig_sales_line( p_line_id );
FETCH c_orig_sales_line INTO orig_line_rec;

IF ( c_orig_sales_line%NOTFOUND OR c_orig_sales_line%NOTFOUND IS NULL ) THEN
  orig_line_rec := NULL;
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_orig_sales_line;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_orig_sales_line%isopen THEN
      CLOSE c_orig_sales_line;
    END IF;
    Cmg_Utility_Pck.write_output(' Sales order line error => '||p_line_id||'-'||SQLERRM);
   WHEN OTHERS THEN
    IF c_orig_sales_line%isopen THEN
      CLOSE c_orig_sales_line;
    END IF;
    Cmg_Utility_Pck.write_output(' Sales order line error => '||p_line_id||'-'||SQLERRM);
END get_orig_line;

PROCEDURE get_line_attrs( p_header_id  IN  oe_order_headers.header_id%TYPE,
                          p_line_id    IN  oe_order_lines.line_id%TYPE )
IS
BEGIN

OPEN  c_line_attribs( p_header_id, p_line_id );
FETCH c_line_attribs INTO line_attribs_rec;

IF ( c_line_attribs%NOTFOUND OR c_line_attribs%NOTFOUND IS NULL ) THEN
  RAISE NO_DATA_FOUND;
END IF;

CLOSE c_line_attribs;

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    IF c_line_attribs%isopen THEN
      CLOSE c_line_attribs;
    END IF;
    line_attribs_rec := NULL;
  WHEN OTHERS THEN
    IF c_line_attribs%isopen THEN
      CLOSE c_line_attribs;
    END IF;
    line_attribs_rec := NULL;
END get_line_attrs;

PROCEDURE update_hdr_status( p_rec        IN  c_cur%ROWTYPE,
                             p_status     IN  hdg_ret_adj_lines_tbl.valid_status_flag%TYPE,
                             p_interface  IN  hdg_ret_adj_header_tbl.valid_status_flag%TYPE )
IS
BEGIN

UPDATE hdg_ret_adj_header_tbl
SET    record_interfaced    = p_status,
       last_update_date     = SYSDATE,
       last_updated_by      = Fnd_Global.user_id
WHERE  adjustment_header_id = p_rec.adjustment_header_id;

END update_hdr_status;

PROCEDURE update_lns_status ( p_rec     IN  c_cur%ROWTYPE,
                              p_reason  IN  hdg_ret_adj_lines_tbl.invalid_reason_code%TYPE,
                              p_status  IN  hdg_ret_adj_lines_tbl.valid_status_flag%TYPE )
IS
BEGIN

UPDATE hdg_ret_adj_lines_tbl
SET    line_interfaced      = p_status,
       last_update_date     = SYSDATE,
       last_updated_by      = Fnd_Global.user_id
WHERE  adjustment_line_id   = p_rec.adjustment_line_id
AND    adjustment_header_id = p_rec.adjustment_header_id;

END update_lns_status;

PROCEDURE update_hdr_status( p_header_id  IN  hdg_ret_adj_header_tbl.adjustment_header_id%TYPE,
                             p_status     IN  hdg_ret_adj_lines_tbl.valid_status_flag%TYPE,
                             p_interface  IN  hdg_ret_adj_header_tbl.valid_status_flag%TYPE )
IS
BEGIN

Cmg_Utility_Pck.write_output('before update hdr status ');

UPDATE hdg_ret_adj_header_tbl
SET    record_interfaced    = p_status,
       last_update_date     = SYSDATE,
       last_updated_by      = Fnd_Global.user_id
WHERE  adjustment_header_id = p_header_id;

Cmg_Utility_Pck.write_output('After update hdr status');

END update_hdr_status;

PROCEDURE update_lns_status ( p_header_id  IN  hdg_ret_adj_header_tbl.adjustment_header_id%TYPE,
                              p_line_id    IN hdg_ret_adj_lines_tbl.adjustment_line_id%TYPE,
                              p_reason     IN  hdg_ret_adj_lines_tbl.invalid_reason_code%TYPE,
                              p_status     IN  hdg_ret_adj_lines_tbl.valid_status_flag%TYPE )
IS
BEGIN

UPDATE hdg_ret_adj_lines_tbl
SET    line_interfaced      = p_status,
       last_update_date     = SYSDATE,
       last_updated_by      = Fnd_Global.user_id
WHERE  adjustment_line_id   = p_line_id
AND    adjustment_header_id = p_header_id;

END update_lns_status;

PROCEDURE insert_header( p_rec  IN  oe_headers_interface%ROWTYPE )
IS
BEGIN

Cmg_Utility_Pck.log_msg(' Inside insert_header',p_rec.orig_sys_document_ref);

--Cmg_Utility_Pck.write_output('inside insert header');

INSERT INTO oe_headers_interface(
  created_by ,
  last_updated_by ,
  creation_date ,
  last_update_date ,
  booked_flag,
  ready_flag ,
  rejected_flag  ,
  operation_code ,
  error_flag ,
  order_source_id ,
  order_type_id ,
  order_category ,
  sold_to_org_id ,
  invoice_customer_id,
  ship_to_customer_id ,
  invoice_to_org_id,
  ship_to_org_id ,
  ship_from_org_id ,
  price_list_id ,
  salesrep_id,
  sales_channel_code ,
  orig_sys_document_ref ,
  ordered_date,
  transactional_curr_code ,
  conversion_type_code ,
  customer_payment_term_id ,
  accounting_rule_id ,
  invoicing_rule_id,
  CONTEXT ,
  attribute1,
  attribute2,
  attribute3,
  attribute4,
  attribute5,
  attribute6,
  attribute7,
  attribute8,
  attribute9,
  attribute10,
  attribute11,
  attribute12,
  attribute13,
  attribute14,
  attribute15,
  attribute16,
  attribute17,
  attribute18,
  attribute19,
  attribute20,
  global_attribute20,
  customer_po_number )
VALUES(
  p_rec.created_by ,
  p_rec.last_updated_by ,
  p_rec.creation_date ,
  p_rec.last_update_date ,
  p_rec.booked_flag,
  p_rec.ready_flag ,
  p_rec.rejected_flag  ,
  p_rec.operation_code ,
  p_rec.error_flag ,
  p_rec.order_source_id ,
  p_rec.order_type_id ,
  p_rec.order_category ,
  p_rec.sold_to_org_id ,
  p_rec.invoice_customer_id,
  p_rec.ship_to_customer_id ,
  p_rec.invoice_to_org_id,
  p_rec.ship_to_org_id ,
  p_rec.ship_from_org_id ,
  p_rec.price_list_id ,
  p_rec.salesrep_id,
  p_rec.sales_channel_code ,
  p_rec.orig_sys_document_ref ,
  p_rec.ordered_date,
  p_rec.transactional_curr_code ,
  p_rec.conversion_type_code ,
  p_rec.customer_payment_term_id ,
  p_rec.accounting_rule_id ,
  p_rec.invoicing_rule_id,
  p_rec.CONTEXT ,
  p_rec.attribute1,
  p_rec.attribute2,
  p_rec.attribute3,
  p_rec.attribute4,
  p_rec.attribute5,
  p_rec.attribute6,
  p_rec.attribute7,
  p_rec.attribute8,
  p_rec.attribute9,
  p_rec.attribute10,
  p_rec.attribute11,
  p_rec.attribute12,
  p_rec.attribute13,
  p_rec.attribute14,
  p_rec.attribute15,
  p_rec.attribute16,
  p_rec.attribute17,
  p_rec.attribute18,
  p_rec.attribute19,
  p_rec.attribute20,
  p_rec.global_attribute20,-- adjustment_header_id
  p_rec.customer_po_number );

--  Cmg_Utility_Pck.write_output('after inserting the header interface table ');

EXCEPTION
  WHEN OTHERS THEN
    Cmg_Utility_Pck.write_output(' Error creating header record => '||p_rec.orig_sys_document_ref);
    RAISE;
END insert_header;

PROCEDURE insert_line( p_rec  IN  oe_lines_interface%ROWTYPE )
IS
BEGIN

Cmg_Utility_Pck.log_msg(' Inside insert_line',p_rec.orig_sys_line_ref);

INSERT INTO oe_lines_interface(
  creation_date,
  created_by,
  last_update_date ,
  last_updated_by ,
  error_flag ,
  operation_code ,
  rejected_flag ,
  orig_sys_document_ref,
  orig_sys_line_ref,
  line_number ,
  order_quantity_uom ,
  ordered_quantity ,
  request_date,
  inventory_item_id ,
  ship_to_customer_id ,
  calculate_price_flag ,
  unit_selling_price ,
  unit_list_price ,
  order_source_id  ,
  ship_to_org_id ,
  ship_from_org_id ,
  pricing_context,
  pricing_attribute1,
  attribute1 ,
  attribute2,
  attribute3,
  attribute4,
  attribute5,
  attribute6,
  attribute7,
  attribute8,
  attribute9 ,
  attribute10,
  attribute11,
  attribute12,
  attribute13,
  attribute14,
  attribute15,
  attribute16,
  attribute17,
  attribute18,
  attribute19,
  attribute20,
  return_context,
  return_attribute1,
  return_attribute2,
  return_reason_code,
  reference_type,
  reference_header_id,
  reference_line_id,
  pricing_date,
  sold_to_org_id,
  invoice_to_org_id,
  global_attribute_category,
  global_attribute1,
  global_attribute2,
  global_attribute3,
  global_attribute4,
  global_attribute5,
  global_attribute6,
  global_attribute7,
  global_attribute8,
  global_attribute9,
  global_attribute10,
  global_attribute11,
  global_attribute12,
  global_attribute13,
  global_attribute14,
  global_attribute15,
  global_attribute16,
  global_attribute17,
  global_attribute18,
  global_attribute19,
  global_attribute20,
  industry_attribute18,
  industry_attribute19,
  industry_attribute20,
  line_category_code,-- SCR 6658
  line_type )-- SCR 6658
VALUES(
  p_rec.creation_date,
  p_rec.created_by,
  p_rec.last_update_date ,
  p_rec.last_updated_by ,
  p_rec.error_flag ,
  p_rec.operation_code ,
  p_rec.rejected_flag ,
  p_rec.orig_sys_document_ref,
  p_rec.orig_sys_line_ref,
  p_rec.line_number ,
  p_rec.order_quantity_uom ,
  p_rec.ordered_quantity ,
  p_rec.request_date,
  p_rec.inventory_item_id ,
  p_rec.ship_to_customer_id ,
  p_rec.calculate_price_flag ,
  p_rec.unit_selling_price ,
  p_rec.unit_list_price ,
  p_rec.order_source_id  ,
  p_rec.ship_to_org_id ,
  p_rec.ship_from_org_id ,
  NVL(p_rec.pricing_context,v_price_context),
  p_rec.pricing_attribute1,
  p_rec.attribute1 ,
  p_rec.attribute2,
  p_rec.attribute3,
  p_rec.attribute4,
   /* if the referenced cover price is null or 0, populate the unit list price from the referenced Sales Order line as the cover price */
  decode(p_rec.attribute5,null,p_rec.unit_list_price,
                          0,p_rec.unit_list_price,
                            p_rec.attribute5),
  p_rec.attribute6,
  p_rec.attribute7,
  p_rec.attribute8,
  p_rec.attribute9 ,
  p_rec.attribute10,
  p_rec.attribute11,
  p_rec.attribute12,
  p_rec.attribute13,
  p_rec.attribute14,
  p_rec.attribute15,
  p_rec.attribute16,
  p_rec.attribute17,
  p_rec.attribute18,
  p_rec.attribute19,
  p_rec.attribute20,
  p_rec.return_context,
  p_rec.return_attribute1,
  p_rec.return_attribute2,
  p_rec.return_reason_code,--NVL(p_rec.return_reason_code,'RETURN'), -- SCR 6658
  p_rec.reference_type,
  p_rec.reference_header_id,
  p_rec.reference_line_id,
  p_rec.pricing_date,
  p_rec.sold_to_org_id,
  p_rec.invoice_to_org_id,
  p_rec.global_attribute_category,
  p_rec.global_attribute1,
  p_rec.global_attribute2,
  p_rec.global_attribute3,
  p_rec.global_attribute4,
  p_rec.global_attribute5,
  p_rec.global_attribute6,
  p_rec.global_attribute7,
  p_rec.global_attribute8,
  p_rec.global_attribute9,
  p_rec.global_attribute10,
  p_rec.global_attribute11,
  p_rec.global_attribute12,
  p_rec.global_attribute13,
  p_rec.global_attribute14,
  p_rec.global_attribute15,
  p_rec.global_attribute16,
  p_rec.global_attribute17,
  p_rec.global_attribute18,
  p_rec.global_attribute19,
  p_rec.global_attribute20,
  p_rec.industry_attribute18,-- refrenced header_id
  p_rec.industry_attribute19,--refrenced_line_id
  p_rec.industry_attribute20, -- adjustment_line_id
  p_rec.line_category_code,-- SCR 6658
  p_rec.line_type );-- SCR 6658

IF p_rec.return_context IS NULL THEN

  INSERT INTO oe_price_atts_interface(
    created_by,
    creation_date,
    last_updated_by,
    last_update_date,
    operation_code,
    orig_sys_document_ref,
    orig_sys_line_ref,
    pricing_context,
    pricing_attribute1,
    order_source_id,
    flex_title )
  VALUES(
    Fnd_Global.user_id,
    SYSDATE,
    Fnd_Global.user_id,
    SYSDATE,
    'CREATE',
    p_rec.orig_sys_document_ref,
    p_rec.orig_sys_line_ref,
    NVL(p_rec.pricing_context,v_price_context),
    p_rec.pricing_attribute1,
    p_rec.order_source_id,
    'QP_ATTR_DEFNS_PRICING' );

END IF;

EXCEPTION
  WHEN OTHERS THEN
    Cmg_Utility_Pck.write_output(' Error creating line record => '||p_rec.orig_sys_document_ref);
    RAISE;
END insert_line;

PROCEDURE set_header( p_rec  IN  ord_tbl )
IS
BEGIN

Cmg_Utility_Pck.log_msg(' Inside set_header',p_rec(p_rec.FIRST).line_orig_header_id);

v_hdr_cnt := v_hdr_cnt + 1;

GET_ORIG_HEADER  ( p_rec(p_rec.FIRST).line_orig_header_id );
-- GET_CUST_INFO    ( p_rec(1).customer_id );
-- GET_NEW_ORD      ( cust_rec );
GET_CUST_ATTS    ( p_rec(p_rec.FIRST).customer_id );

IF p_rec(p_rec.first).order_type_id IS NULL THEN
  GET_ORD_TYPE     ( cust_attr_rec.order_type_id );
ELSE
  GET_ORD_TYPE     ( p_rec(p_rec.FIRST).order_type_id );
END IF;

intf_head_rec                          := NULL;

intf_head_rec.created_by               := p_rec(p_rec.FIRST).created_by;
intf_head_rec.last_updated_by          := p_rec(p_rec.FIRST).created_by;
intf_head_rec.creation_date            := v_sysdate;
intf_head_rec.last_update_date         := intf_head_rec.creation_date;
intf_head_rec.booked_flag              := 'Y';
intf_head_rec.ready_flag               := 'Y';
intf_head_rec.rejected_flag            := 'N';
intf_head_rec.operation_code           := 'CREATE';
-- intf_head_rec.error_flag               := 'Y';

IF p_rec(p_rec.FIRST).adjustment_flag = 'Y' THEN
           -- Since header is a manual adjustment, order source
           -- must either be EN MANUAL ADJ or HDG MANUAL ADJ
  intf_head_rec.order_source_id          := GET_ORD_SOURCE('HDG MANUAL ADJ');
  LOAD_SOURCE('HDG MANUAL ADJ');

ELSE
-- Must be a Price Change or Customer Transfer
  IF p_rec(p_rec.FIRST).soh_original_system_ref LIKE '%GPC%' THEN

    intf_head_rec.order_source_id          := GET_ORD_SOURCE('HDG AUTO PRICE ADJ');
    LOAD_SOURCE('HDG AUTO PRICE ADJ');

  ELSIF p_rec(p_rec.FIRST).soh_original_system_ref LIKE '%ACT%' THEN

    intf_head_rec.order_source_id          := GET_ORD_SOURCE('HDG CUSTOMER TRANSFERS');
    LOAD_SOURCE('HDG CUSTOMER TRANSFERS');

  ELSE
  -- Must be an electronically processed return
   Cmg_Utility_Pck.write_output('getting return  source id');

   intf_head_rec.order_source_id          := GET_ORD_SOURCE('HDG RETURNS');
    LOAD_SOURCE('HDG RETURNS');
    Cmg_Utility_Pck.write_output('after load_source hdg returns ');

  END IF;

END IF;

intf_head_rec.sold_to_org_id           := p_rec(p_rec.FIRST).customer_id;
intf_head_rec.invoice_customer_id      := p_rec(p_rec.FIRST).customer_id;
intf_head_rec.ship_to_customer_id      := p_rec(p_rec.FIRST).customer_id;
intf_head_rec.invoice_to_org_id        := p_rec(p_rec.FIRST).bill_to_site_use_id;
intf_head_rec.ship_to_org_id           := p_rec(p_rec.FIRST).ship_to_site_use_id;
intf_head_rec.ship_from_org_id         := p_rec(p_rec.FIRST).warehouse_id;
intf_head_rec.price_list_id            := NVL(p_rec(p_rec.FIRST).price_list_id,cust_attr_rec.price_list_id);
intf_head_rec.salesrep_id              := NVL(NVL(p_rec(p_rec.FIRST).salesrep_id,cust_attr_rec.primary_salesrep_id),v_salesrep_id);
intf_head_rec.sales_channel_code       := NVL(p_rec(p_rec.FIRST).sales_channel_code,'HDG DEFAULT');

intf_head_rec.ordered_date             := SYSDATE;  -- nvl(p_rec(p_rec.FIRST).processed_date,sysdate);
intf_head_rec.transactional_curr_code  := NVL(ord_type_rec.currency_code,cust_attr_rec.currency_code);
intf_head_rec.conversion_type_code     := ord_type_rec.conversion_type_code;

intf_head_rec.customer_payment_term_id := orig_head_rec.payment_term_id;

intf_head_rec.accounting_rule_id       := ord_type_rec.accounting_rule_id;
intf_head_rec.invoicing_rule_id        := ord_type_rec.invoicing_rule_id;

intf_head_rec.orig_sys_document_ref    := p_rec(p_rec.FIRST).adjustment_header_id||'-'||
                                          p_rec(p_rec.FIRST).tally_nr||'-'||
                                          p_rec(p_rec.FIRST).customer_ref_nr;

intf_head_rec.customer_po_number       := p_rec(p_rec.FIRST).customer_ref_nr;

intf_head_rec.order_type_id            := NVL(ord_type_rec.transaction_type_id,cust_attr_rec.order_type_id);
intf_head_rec.order_category           := ord_type_rec.order_category_code;

-- dff definitions
intf_head_rec.CONTEXT                  := ord_type_rec.order_category_code;
intf_head_rec.attribute1               := orig_head_rec.attribute1;
intf_head_rec.attribute2               := orig_head_rec.attribute2;
intf_head_rec.attribute3               := p_rec(p_rec.FIRST).customer_ref_nr;
intf_head_rec.attribute4               := p_rec(p_rec.FIRST).return_date;

-- SCR 6658
-- SCR 8637 ( Added %RV-% to include Genera Customer Account Returns Reversals for CMG Publishers)
IF p_rec(p_rec.FIRST).customer_ref_nr like '%RV' OR p_rec(p_rec.FIRST).customer_ref_nr like '%RV-%'then
  intf_head_rec.attribute5 := null;
ELSE
intf_head_rec.attribute5               := p_rec(p_rec.FIRST).tally_nr;
END IF;

intf_head_rec.attribute6               := orig_head_rec.attribute6;
intf_head_rec.attribute7               := orig_head_rec.attribute7;
intf_head_rec.attribute8               := orig_head_rec.attribute8;
intf_head_rec.attribute9               := orig_head_rec.attribute9;
intf_head_rec.attribute10              := orig_head_rec.attribute10;
intf_head_rec.attribute11              := orig_head_rec.attribute11;
intf_head_rec.attribute12              := orig_head_rec.attribute12;
intf_head_rec.attribute13              := orig_head_rec.attribute13;
intf_head_rec.attribute14              := orig_head_rec.attribute14;
intf_head_rec.attribute15              := orig_head_rec.attribute15;
intf_head_rec.attribute16              := orig_head_rec.attribute16;
intf_head_rec.attribute17              := orig_head_rec.attribute17;
intf_head_rec.attribute18              := orig_head_rec.attribute18;
intf_head_rec.attribute19              := orig_head_rec.attribute19;
intf_head_rec.global_attribute20       := p_rec(p_rec.FIRST).adjustment_header_id;

Cmg_Utility_Pck.write_output('Loading into header table');

INSERT_HEADER( intf_head_rec );
Cmg_Utility_Pck.write_output('After insert_header done ');

Cmg_Utility_Pck.write_output('Before update header status ');

UPDATE_HDR_STATUS( p_rec(p_rec.FIRST).adjustment_header_id, 'Y', NULL );

Cmg_Utility_Pck.write_output('after update header status ');

EXCEPTION
  WHEN OTHERS THEN
    Cmg_Utility_Pck.write_output(' set_header: Err others => '||SQLERRM);
    RAISE;
END set_header;

PROCEDURE set_line( p_rec  IN  ord_tbl )
IS
BEGIN

FOR j IN p_rec.FIRST..p_rec.LAST LOOP


  GET_ORIG_LINE  ( p_rec(j).original_order_line_id );
  GET_ITEM_INFO  ( p_rec(j).inventory_item_id );
  GET_LINE_ATTRS ( orig_line_rec.header_id, orig_line_rec.line_id );
  get_edition    ( p_rec(j).inventory_item_id, p_rec(j).issue_code );

/* Get_Edition procedure is modified by passing the necessary issue_code to get the active UPC from the revisions table */
 /* GET_EDITION    ( p_rec(j).inventory_item_id, NULL); */ -- commented out.

  intf_line_rec                       := NULL;

  intf_line_rec.creation_date         := v_sysdate;
  intf_line_rec.created_by            := p_rec(j).created_by;
  intf_line_rec.last_update_date      := v_sysdate;
  intf_line_rec.last_updated_by       := p_rec(j).created_by;
  intf_line_rec.operation_code        := 'CREATE';
  intf_line_rec.rejected_flag         := 'N';

  intf_line_rec.pricing_context       := NVL(line_attribs_rec.pricing_context,orig_line_rec.pricing_context);
  intf_line_rec.pricing_attribute1    := NVL(NVL(line_attribs_rec.pricing_attribute1,
                                                 orig_line_rec.pricing_attribute1),p_rec(j).upc);


  intf_line_rec.orig_sys_document_ref := intf_head_rec.orig_sys_document_ref;
  intf_line_rec.orig_sys_line_ref     := p_rec(j).adjustment_line_id;
  intf_line_rec.line_number           := j;
  intf_line_rec.order_quantity_uom    := item_rec.primary_uom_code;
  intf_line_rec.ordered_quantity      := p_rec(j).quantity;
  intf_line_rec.request_date          := v_sysdate;
  intf_line_rec.inventory_item_id     := p_rec(j).inventory_item_id;
  intf_line_rec.ship_to_customer_id   := intf_head_rec.ship_to_customer_id;
  intf_line_rec.attribute4            := NVL(NVL(p_rec(j).bipad,item_rec.bipad_code),orig_line_rec.attribute4); -- bipad
  intf_line_rec.calculate_price_flag  := 'N';

  intf_line_rec.unit_list_price       := NVL(NVL(orig_line_rec.attribute5,p_rec(j).cover_price),GET_LIST_PRICE( intf_head_rec, intf_line_rec ));
  intf_line_rec.attribute5            := NVL(NVL(orig_line_rec.attribute5,p_rec(j).cover_price),GET_LIST_PRICE( intf_head_rec, intf_line_rec ));
 -- intf_line_rec.unit_selling_price    := NVL(orig_line_rec.unit_selling_price,p_rec(j).unit_price);

   IF orig_line_rec.unit_selling_price = 0 OR orig_line_rec.unit_selling_price IS NULL THEN
            intf_line_rec.unit_selling_price := NVL(p_rec(j).unit_price,0);
   ELSE
        intf_line_rec.unit_selling_price :=orig_line_rec.unit_selling_price;
   END IF;


   IF (p_rec(j).invalid_reason_code IS NOT NULL ) THEN

    IF ( p_rec(j).user_rejected_flag     = 'Y' ) THEN

      intf_line_rec.unit_selling_price   := 0;
      intf_line_rec.attribute5 := NVL(NVL(orig_line_rec.attribute5,p_rec(j).cover_price),GET_LIST_PRICE( intf_head_rec, intf_line_rec ));
      intf_line_rec.unit_list_price := NVL(NVL(orig_line_rec.attribute5,p_rec(j).cover_price),GET_LIST_PRICE( intf_head_rec, intf_line_rec ));

     ELSIF  ( p_rec(j).override_flag ='Y' ) THEN
          IF (p_rec(j).invalid_reason_code IN ('NOT BILLED' ,'BAD ISSUE','BAD PRODUCT'))THEN
             intf_line_rec.calculate_price_flag := 'N';

                      IF orig_line_rec.attribute5 = 0 OR orig_line_rec.attribute5 IS NULL THEN
             intf_line_rec.unit_list_price := NVL(p_rec(j).cover_price,0);
             intf_line_rec.attribute5 := NVL(p_rec(j).cover_price,0);
           --  Cmg_Utility_Pck.write_output(' inside 0 or null  Cover price '|| p_rec(j).cover_price);
          END IF;


          IF orig_line_rec.unit_selling_price = 0 OR orig_line_rec.unit_selling_price IS NULL THEN
            intf_line_rec.unit_selling_price := NVL(p_rec(j).unit_price,0);
          --  Cmg_Utility_Pck.write_output('inside 0 or null  selling price '|| p_rec(j).unit_price );
          END IF;


            intf_line_rec.price_list_id        := cust_attr_rec.price_list_id;
         END IF;

     END IF;

   END IF;


    IF p_rec(j).invalid_reason_code  IN ('BAD PRODUCT' ,'BAD ISSUE','NOT BILLED') THEN

        intf_line_rec.attribute4 :=  NVL(p_rec(j).isbn,item_rec.bipad_code);
        intf_line_rec.inventory_item_id     := NVL(p_rec(j).inventory_item_id,invalid_item_rec.bad_inv_item_id);
    END IF;

  intf_line_rec.pricing_date          := NVL(orig_line_rec.pricing_date,orig_head_rec.ordered_date);

  intf_line_rec.order_source_id       := intf_head_rec.order_source_id;
  intf_line_rec.ship_to_org_id        := intf_head_rec.ship_to_org_id;
  intf_line_rec.ship_from_org_id      := intf_head_rec.ship_from_org_id;
  intf_line_rec.sold_to_org_id        := intf_head_rec.sold_to_org_id;
  intf_line_rec.invoice_to_org_id     := intf_head_rec.invoice_to_org_id;
-- dff definitions
  intf_line_rec.CONTEXT               := NULL;
  intf_line_rec.attribute1            := NVL(p_rec(j).issue_code,orig_line_rec.attribute1);   -- issue code
  intf_line_rec.attribute2            := NVL(orig_line_rec.attribute2,edition_rec.cover_date);  -- cover date
  intf_line_rec.attribute3            := NVL(orig_line_rec.attribute3,edition_rec.edition);  -- edition
  intf_line_rec.attribute6            := NVL(orig_line_rec.attribute6,edition_rec.on_sale_date); -- on sale date
  intf_line_rec.attribute7            := NVL(orig_line_rec.attribute7,edition_rec.off_sale_date); -- off sale date
  intf_line_rec.attribute8            := NVL(orig_line_rec.attribute8,edition_rec.last_return_date); -- last return date
  intf_line_rec.attribute9            := orig_line_rec.attribute9;  -- returnable status
  intf_line_rec.attribute10           := NULL;  -- encore interface flag
  intf_line_rec.attribute11           := orig_line_rec.attribute11;
 -- intf_line_rec.attribute12           := orig_line_rec.attribute12;

 -- SCR 6658
 -- SCR 8637 ( Added %RV-% to include GENERA Account Returns Reversals for CMG Publishers)
  IF p_rec(p_rec.FIRST).customer_ref_nr like '%RV' OR p_rec(p_rec.FIRST).customer_ref_nr like '%RV-%' then
    intf_line_rec.attribute13           := 'S';
    intf_line_rec.attribute14           :=  NULL;
    intf_line_rec.line_category_code    := 'ORDER';
    intf_line_rec.line_type             := 'CMG Order Line';
    intf_line_rec.return_reason_code    :=  NVL(p_rec(j).invalid_reason_code,null);
  ELSE
    intf_line_rec.attribute13           := NULL;
    intf_line_rec.attribute14           := NVL(p_rec(j).invalid_reason_code,'RETURN');
    intf_line_rec.line_category_code    := NULL;
    intf_line_rec.line_type             := NULL;
    intf_line_rec.return_reason_code    := NVL(p_rec(j).invalid_reason_code,'RETURN');
  END IF;


  intf_line_rec.attribute15           := orig_line_rec.attribute15;
  intf_line_rec.attribute16           := orig_line_rec.attribute16;
  intf_line_rec.attribute17           := orig_line_rec.attribute17;
  intf_line_rec.attribute18           := orig_line_rec.attribute18;
  intf_line_rec.attribute19           := orig_line_rec.attribute19;
  intf_line_rec.industry_attribute20  := p_rec(j).adjustment_line_id;
  intf_line_rec.industry_attribute18  := orig_line_rec.header_id;
  intf_line_rec.industry_attribute19  := orig_line_rec.line_id;


  INSERT_LINE( intf_line_rec );

  UPDATE_LNS_STATUS( p_rec(j).adjustment_header_id,
                     p_rec(j).adjustment_line_id,
                     NULL,
                     'Y' );

END LOOP;

EXCEPTION
  WHEN OTHERS THEN
    Cmg_Utility_Pck.write_output(' set_line: Err others => '||SQLERRM);
    RAISE;
END set_line;

PROCEDURE load_table( p_rec  IN  c_cur%ROWTYPE )
IS
BEGIN

Cmg_Utility_Pck.log_msg(' Inside load_table',p_rec.adjustment_header_id);

IF p_rec.line_valid_status_flag = 'N' THEN

fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started8'||p_rec.line_valid_status_flag);
  Cmg_Utility_Pck.log_msg('  line_valid_status_flag',p_rec.line_valid_status_flag);

  load_flag := FALSE;

/*  elsif ( p_rec.override_flag = 'N' or p_rec.user_rejected_flag = 'N' ) then

  v_returnable_qty := hdg_rmaval_pck.hdg_validate_netsale_fnc(
                                      p_rec.netsale_revalidation_level,
                                      p_rec.customer_id,
                                      p_rec.inventory_item_id,
                                      p_rec.warehouse_id,
                                      p_rec.issue_code,
                                      p_rec.quantity,
                                      p_rec.ship_to_site_use_id);

  IF v_returnable_qty < 0 THEN
    cmg_utility_pck.write_output('Net Sale Validation Failed'||
                      ' for the Adj Line Id '||p_rec.adjustment_line_id);

    UPDATE_LNS_STATUS( p_rec, 'OVERDRAW', 'N' );

    UPDATE_HDR_STATUS( p_rec, 'N', null );

    load_flag := FALSE;

  end if;  */
END IF;

Cmg_Utility_Pck.write_output('Inside the load_table procedure');


i := i + 1;

ord_rec(i).adjustment_header_id         := p_rec.adjustment_header_id;
ord_rec(i).created_by                   := p_rec.created_by;
ord_rec(i).creation_date                := p_rec.creation_date;
ord_rec(i).last_updated_by              := p_rec.last_updated_by;
ord_rec(i).last_update_date             := p_rec.last_update_date;
ord_rec(i).customer_ref_nr              := p_rec.customer_ref_nr;
ord_rec(i).tally_nr                     := p_rec.tally_nr;
ord_rec(i).adjustment_flag              := p_rec.adjustment_flag;
ord_rec(i).record_interfaced            := p_rec.record_interfaced;
ord_rec(i).account_nr                   := p_rec.account_nr;
ord_rec(i).source                       := p_rec.source;
ord_rec(i).total_copies                 := p_rec.total_copies;
ord_rec(i).customer_id                  := p_rec.customer_id;
ord_rec(i).customer_name                := p_rec.customer_name;
ord_rec(i).bill_to_site_use_id          := p_rec.bill_to_site_use_id;
ord_rec(i).ship_to_site_use_id          := p_rec.ship_to_site_use_id;
ord_rec(i).return_date                  := p_rec.return_date;
ord_rec(i).processed_date               := p_rec.processed_date;
ord_rec(i).employee_assigned_to         := p_rec.employee_assigned_to;
ord_rec(i).order_category               := p_rec.order_category;
ord_rec(i).order_type_id                := p_rec.order_type_id;
ord_rec(i).valid_status_flag            := p_rec.valid_status_flag;
ord_rec(i).duplicate_flag               := p_rec.duplicate_flag;
ord_rec(i).store_nr                     := p_rec.store_nr;
ord_rec(i).price_list_id                := p_rec.price_list_id;
ord_rec(i).salesrep_id                  := p_rec.salesrep_id;
ord_rec(i).sales_channel_code           := p_rec.sales_channel_code;
ord_rec(i).original_order_header_id     := p_rec.original_order_header_id;
ord_rec(i).soh_original_system_ref      := p_rec.soh_original_system_ref;
ord_rec(i).line_orig_header_id          := p_rec.line_orig_header_id;
ord_rec(i).original_order_line_id       := p_rec.original_order_line_id;
ord_rec(i).extended_price               := p_rec.extended_price;
ord_rec(i).unit_price                   := p_rec.unit_price;
ord_rec(i).inventory_item_id            := p_rec.inventory_item_id;
ord_rec(i).warehouse_id                 := p_rec.warehouse_id;
ord_rec(i).line_nr                      := p_rec.line_nr;
ord_rec(i).add_on_code                  := p_rec.add_on_code;
ord_rec(i).adjustment_line_id           := p_rec.adjustment_line_id;
ord_rec(i).item_nr                      := p_rec.item_nr;
ord_rec(i).quantity                     := p_rec.quantity;
ord_rec(i).line_adjustment_flag         := p_rec.line_adjustment_flag;
ord_rec(i).corrected_flag               := p_rec.corrected_flag;
ord_rec(i).user_rejected_flag           := p_rec.user_rejected_flag;
ord_rec(i).override_flag                := p_rec.override_flag;
ord_rec(i).line_interfaced              := p_rec.line_interfaced;
ord_rec(i).bar_code                     := p_rec.bar_code;
ord_rec(i).bipad                        := p_rec.bipad;
ord_rec(i).isbn                         := p_rec.isbn;
ord_rec(i).magazine                     := p_rec.magazine;
ord_rec(i).issue_code                   := p_rec.issue_code;
ord_rec(i).cover_date_txt               := p_rec.cover_date_txt;
ord_rec(i).en_title                     := p_rec.en_title;
ord_rec(i).upc                          := p_rec.upc;
ord_rec(i).cover_price                  := p_rec.cover_price;
ord_rec(i).line_valid_status_flag       := p_rec.line_valid_status_flag;
ord_rec(i).invalid_reason_code          := p_rec.invalid_reason_code;
ord_rec(i).netsale_revalidation_level   := p_rec.netsale_revalidation_level;
ord_rec(i).sol_original_system_line_ref := p_rec.sol_original_system_line_ref;

--Cmg_Utility_Pck.write_output('after the load_table procedure');

END load_table;

-- start this puppy
PROCEDURE main( errbuf  OUT VARCHAR2,
                retcode OUT NUMBER) IS

BEGIN

Cmg_Utility_Pck.write_output('');
Cmg_Utility_Pck.write_output('       Log File For RMA Import Program');
Cmg_Utility_Pck.write_output('       --------------------------------------');
Cmg_Utility_Pck.write_output('');

Cmg_Utility_Pck.log_msg('CMG_LOAD_RET_PCK.MAIN: Started',TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));


--CHECK FOR ANY MISMATCH IN ORDER TYPES AND MARK THEM AS INVALID (FOREIGN MIGRATION)
MISMATCH_ORDERTYPE_PRC;
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started1');
load_flag := FALSE;
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started2');
INTIALIZATION;
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started3');

FOR rec IN c_cur LOOP

--Cmg_Utility_Pck.write_outpu--Cmg_Utility_Pck.write_output('v_hold'||v_hold);


  -- Cmg_Utility_Pck.write_output('load flag'|| load_flag);
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started4');
  IF ( v_hold IS NULL OR v_hold <> rec.adjustment_header_id ) THEN

--  Cmg_Utility_Pck.write_output('2');
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started5');

    IF load_flag THEN
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started6');
      SET_HEADER( ord_rec );
--      Cmg_Utility_Pck.write_output('3');
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started7');
      SET_LINE( ord_rec );
--Cmg_Utility_Pck.write_output('4');

    END IF;

    ord_rec.DELETE;

    load_flag       := TRUE;

    i := 0;

    v_hold := rec.adjustment_header_id;

  END IF;

--Cmg_Utility_Pck.write_output('5 ');

  LOAD_TABLE( rec );

--  Cmg_Utility_Pck.write_output('after the load table procedure');
 -- Cmg_Utility_Pck.write_output('5-test');

END LOOP;

Cmg_Utility_Pck.log_msg(' Count',ord_rec.COUNT);

Cmg_Utility_Pck.write_output('count='||ord_rec.count);

IF ( ord_rec.COUNT > 0 AND load_flag ) THEN

--Cmg_Utility_Pck.write_output('6 ');

  SET_HEADER( ord_rec );
fnd_file.put_line(fnd_file.log,'CMG_LOAD_RET_PCK.MAIN: Started9');
  SET_LINE( ord_rec );

END IF;

Cmg_Utility_Pck.write_output(' Total number of RMAs => '||v_hdr_cnt);
Cmg_Utility_Pck.write_output(' ');

--/*test

IF v_hdr_cnt > 0 THEN -- call order import

  FOR x IN src_rec.FIRST..src_rec.LAST LOOP

    Hdg_Ret_Global_Pck.HDG_ORDER_IMPORT_PRC(v_retcode,
                                            v_errbuf,
                                            v_dphase,
                                            v_dstatus,
                                            GET_ORD_SOURCE(src_rec(x).source_name),
                                            v_filename,
                                            GET_THREAD_COUNT );

    Cmg_Utility_Pck.write_output(' Following Order Import Errors Occurred ');
    Cmg_Utility_Pck.write_output(' ');

    FOR intf_rec IN c_intf_status( GET_ORD_SOURCE(src_rec(x).source_name), v_request_id ) LOOP

      Cmg_Utility_Pck.write_output(' Orig Ref => '||intf_rec.orig_sys_document_ref||
         ' Error => '||intf_rec.entity_code||'-'||intf_rec.message_text);

    END LOOP;

  END LOOP;

  Cmg_Ref_Update_Pck.UPDATE_REF( errbuf, retcode );

  v_err_count := ERR_COUNT( v_request_id );

  Cmg_Utility_Pck.write_output(' Number of processed RMAs => '||(NVL(v_hdr_cnt,0) - NVL(v_err_count,0)));
  Cmg_Utility_Pck.write_output(' Number of erred     RMAs => '||v_err_count);
  Cmg_Utility_Pck.write_output('');

END IF;

--*/ --test

COMMIT;

Cmg_Utility_Pck.write_output('---------------------------------------------------');
Cmg_Utility_Pck.write_output('End of RMA Import log file');

Cmg_Utility_Pck.log_msg('CMG_LOAD_RET_PCK.MAIN: Ended',TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS'));

retcode := NVL(retcode,SQLCODE);
errbuf  := 'CMG_LOAD_RET_PCK.MAIN: Completed'||errbuf;

EXCEPTION
 WHEN OTHERS THEN
   Cmg_Utility_Pck.write_output(SQLERRM);
   retcode := SQLCODE;
   errbuf  := SUBSTR('CMG_LOAD_RET_PCK.MAIN: Error Others => '||SQLERRM,1,150);
   ROLLBACK;
END main;

END Cmg_Load_Ret_Pck;

/